#Requires -Version 5.1
# =============================================================================
# Collect-ClusterStatus.ps1
# Zbiera status klastrów Windows i zapisuje do JSON
# Uruchamiany co 5 minut (razem z Collect-AllGroups.ps1)
# =============================================================================

$BasePath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
$ClustersConfigPath = "D:\PROD_REPO_DATA\IIS\Cluster\clusters.json"
$OutputPath = "$BasePath\data\infra_ClustersWindows.json"
$LogPath = "$BasePath\ServerHealthMonitor.log"
$LogMaxAgeHours = 48

$ErrorActionPreference = "Continue"

function Write-Log {
    param([string]$Message)
    if (Test-Path $LogPath) {
        $logFile = Get-Item $LogPath
        if ($logFile.LastWriteTime -lt (Get-Date).AddHours(-$LogMaxAgeHours)) {
            $archiveName = "$BasePath\ServerHealthMonitor_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            Move-Item $LogPath $archiveName -Force
        }
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [CLUSTERS] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

# --- Wczytaj konfigurację klastrów ---
if (-not (Test-Path $ClustersConfigPath)) {
    Write-Log "BLAD: Brak pliku konfiguracji: $ClustersConfigPath"
    exit 1
}

$config = Get-Content $ClustersConfigPath -Raw | ConvertFrom-Json
$allClusters = @($config.clusters)

if ($allClusters.Count -eq 0) {
    Write-Log "BLAD: Brak klastrow w konfiguracji"
    exit 1
}

# Zbierz wszystkie nazwy FQDN klastrów do jednej listy
# OPTYMALIZACJA: List[object] zamiast ArrayList
$clusterList = [System.Collections.Generic.List[object]]::new()
foreach ($cg in $allClusters) {
    foreach ($srv in $cg.servers) {
        $clusterList.Add(@{ FQDN = $srv; Type = $cg.cluster_type })
    }
}

Write-Log "START zbierania statusu klastrow ($($clusterList.Count) klastrow)"
$startTime = Get-Date
$clusterResults = [System.Collections.Generic.List[object]]::new()
$logBuffer = [System.Collections.Generic.List[string]]::new()

# --- Zbieranie danych z klastrów ---
# OPTYMALIZACJA: Używamy runspace pool dla równoległego przetwarzania klastrów
$maxThreads = [Math]::Min($clusterList.Count, 10)  # Max 10 równoległych połączeń

$scriptBlock = {
    param($clusterFQDN, $clusterType)
    
    try {
        # Pobierz nazwę klastra
        $clusterObj = Get-Cluster -Name $clusterFQDN -ErrorAction Stop
        $clusterName = $clusterObj.Name

        # Pobierz węzły - jedno zapytanie
        $rawNodes = @(Get-ClusterNode -Cluster $clusterFQDN -ErrorAction Stop)

        # Pobierz interfejsy sieciowe - jedno zapytanie dla wszystkich węzłów
        $allInterfaces = @()
        try {
            $allInterfaces = @(Get-ClusterNetworkInterface -Cluster $clusterFQDN -ErrorAction SilentlyContinue)
        } catch {}

        # Buduj listę węzłów z adresami IP (lokalne przetwarzanie bez RPC)
        $nodes = @($rawNodes | ForEach-Object {
            $nodeName = $_.Name
            $nodeIPs = ($allInterfaces | Where-Object { $_.Node -eq $nodeName } |
                        ForEach-Object { $_.Address }) -join ", "
            @{
                Name        = $nodeName
                State       = $_.State.ToString()
                NodeWeight  = $_.NodeWeight
                DynamicWeight = $_.DynamicWeight
                IPAddresses = if ($nodeIPs) { $nodeIPs } else { "N/A" }
            }
        })

        # Pobierz role i zasoby - dwa zapytania zamiast N
        $rawRoles = @(Get-ClusterGroup -Cluster $clusterFQDN -ErrorAction Stop)
        $allResources = @()
        try {
            $allResources = @(Get-ClusterResource -Cluster $clusterFQDN -ErrorAction SilentlyContinue)
        } catch {}

        # OPTYMALIZACJA: Batch pobieranie parametrów IP - filtruj tylko IP Address resources
        $ipResources = @($allResources | Where-Object { $_.ResourceType -eq "IP Address" })
        $ipParams = @{}
        
        # Użyj pipeline zamiast foreach dla lepszej wydajności
        $ipResources | ForEach-Object {
            try {
                $addr = (Get-ClusterParameter -InputObject $_ -Name Address -ErrorAction SilentlyContinue).Value
                if ($addr) {
                    $ownerGroup = $_.OwnerGroup.ToString()
                    if ($ipParams.ContainsKey($ownerGroup)) {
                        $ipParams[$ownerGroup] += ", $addr"
                    } else {
                        $ipParams[$ownerGroup] = $addr
                    }
                }
            } catch {}
        }

        $roles = @($rawRoles | ForEach-Object {
            $roleName = $_.Name
            @{
                Name        = $roleName
                State       = $_.State.ToString()
                OwnerNode   = $_.OwnerNode.ToString()
                IPAddresses = if ($ipParams.ContainsKey($roleName)) { $ipParams[$roleName] } else { "" }
            }
        })

        @{
            Success     = $true
            ClusterName = $clusterName
            FQDN        = $clusterFQDN
            ClusterType = $clusterType
            Status      = "Online"
            Nodes       = $nodes
            Roles       = $roles
            Error       = $null
        }
    }
    catch {
        @{
            Success     = $false
            ClusterName = $clusterFQDN -replace '\..*$', ''
            FQDN        = $clusterFQDN
            ClusterType = $clusterType
            Status      = "Error"
            Nodes       = @()
            Roles       = @()
            Error       = $_.Exception.Message
        }
    }
}

# OPTYMALIZACJA: Runspace Pool zamiast Start-Job (znacznie szybsze)
if ($clusterList.Count -eq 1) {
    # Jeden klaster - wykonaj synchronicznie
    $result = & $scriptBlock -clusterFQDN $clusterList[0].FQDN -clusterType $clusterList[0].Type
    if ($result.Success) {
        $logBuffer.Add("OK: $($result.ClusterName) ($($result.ClusterType)) - $($result.Nodes.Count) wezlow, $($result.Roles.Count) rol")
    } else {
        $logBuffer.Add("FAIL: $($result.FQDN) - $($result.Error)")
    }
    $clusterResults.Add($result)
} else {
    # Wiele klastrów - użyj Runspace Pool dla równoległości
    $runspacePool = [RunspaceFactory]::CreateRunspacePool(1, $maxThreads)
    $runspacePool.Open()

    $runspaces = [System.Collections.Generic.List[object]]::new()

    foreach ($cluster in $clusterList) {
        $ps = [PowerShell]::Create()
        $ps.AddScript($scriptBlock).AddArgument($cluster.FQDN).AddArgument($cluster.Type) | Out-Null
        $ps.RunspacePool = $runspacePool
        $runspaces.Add(@{
            PowerShell = $ps
            Handle = $ps.BeginInvoke()
            FQDN = $cluster.FQDN
        })
    }

    # Zbierz wyniki
    foreach ($rs in $runspaces) {
        try {
            $result = $rs.PowerShell.EndInvoke($rs.Handle)
            if ($result -and $result.Count -gt 0) {
                $r = $result[0]
                if ($r.Success) {
                    $logBuffer.Add("OK: $($r.ClusterName) ($($r.ClusterType)) - $($r.Nodes.Count) wezlow, $($r.Roles.Count) rol")
                } else {
                    $logBuffer.Add("FAIL: $($r.FQDN) - $($r.Error)")
                }
                $clusterResults.Add($r)
            }
        }
        catch {
            $logBuffer.Add("FAIL: $($rs.FQDN) - $($_.Exception.Message)")
            $clusterResults.Add(@{
                Success = $false
                ClusterName = $rs.FQDN -replace '\..*$', ''
                FQDN = $rs.FQDN
                ClusterType = "Unknown"
                Status = "Error"
                Nodes = @()
                Roles = @()
                Error = $_.Exception.Message
            })
        }
        finally {
            $rs.PowerShell.Dispose()
        }
    }

    $runspacePool.Close()
    $runspacePool.Dispose()
}

# --- Zapisz wynik ---
$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
$onlineCount = @($clusterResults | Where-Object { $_.Status -eq "Online" }).Count

$output = @{
    LastUpdate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $duration
    TotalClusters      = $clusterResults.Count
    OnlineCount        = $onlineCount
    FailedCount        = $clusterResults.Count - $onlineCount
    Clusters           = @($clusterResults)
}

$output | ConvertTo-Json -Depth 10 | Out-File $OutputPath -Encoding UTF8 -Force

# OPTYMALIZACJA: Zapis wszystkich logów jednorazowo na końcu
$logBuffer.Add("KONIEC: ${duration}s (OK: $onlineCount, FAIL: $($clusterResults.Count - $onlineCount))")
$logBuffer | ForEach-Object { Write-Log $_ }
