#Requires -Version 5.1
# =============================================================================
# Collect-ClusterStatus.ps1
# Zbiera status klastrów Windows i zapisuje do JSON
# Uruchamiany co 5 minut (razem z Collect-AllGroups.ps1)
# =============================================================================

$ScriptPath = $PSScriptRoot
$ConfigFile = Join-Path (Split-Path $ScriptPath -Parent) "app-config.json"

# Wczytaj konfigurację
if (Test-Path $ConfigFile) {
    $appConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $BasePath = $appConfig.paths.basePath
    $DataPath = $appConfig.paths.dataPath
    $LogsPath = $appConfig.paths.logsPath
    $ConfigPath = $appConfig.paths.configPath
} else {
    $BasePath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
    $DataPath = "$BasePath\data"
    $LogsPath = "$BasePath\logs"
    $ConfigPath = "$BasePath\config"
}

# Upewnij się że katalogi istnieją
@($DataPath, $LogsPath) | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }
}

$OutputPath = "$DataPath\infra_ClustersWindows.json"
$LogPath = "$LogsPath\ServerHealthMonitor.log"
$LogMaxAgeHours = 48

$ErrorActionPreference = "Continue"

function Write-Log {
    param([string]$Message)
    if (Test-Path $LogPath) {
        $logFile = Get-Item $LogPath
        if ($logFile.LastWriteTime -lt (Get-Date).AddHours(-$LogMaxAgeHours)) {
            $archiveName = "$LogsPath\ServerHealthMonitor_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            Move-Item $LogPath $archiveName -Force
        }
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [CLUSTERS] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

# --- Wczytaj konfigurację klastrów ---
# Sprawdź kilka możliwych lokalizacji pliku clusters.json
$possiblePaths = @(
    "$ConfigPath\clusters.json",
    "$BasePath\clusters.json",
    "D:\PROD_REPO_DATA\IIS\Cluster\clusters.json"
)

$ClustersConfigPath = $null
foreach ($path in $possiblePaths) {
    if (Test-Path $path) {
        $ClustersConfigPath = $path
        break
    }
}

if (-not $ClustersConfigPath) {
    Write-Log "BLAD: Brak pliku konfiguracji clusters.json. Sprawdzono:"
    foreach ($path in $possiblePaths) {
        Write-Log "  - $path"
    }
    exit 1
}

Write-Log "Uzywam konfiguracji: $ClustersConfigPath"

$config = Get-Content $ClustersConfigPath -Raw | ConvertFrom-Json
$allClusters = @($config.clusters)

if ($allClusters.Count -eq 0) {
    Write-Log "BLAD: Brak klastrow w konfiguracji"
    exit 1
}

# Zbierz wszystkie nazwy FQDN klastrów do jednej listy
$clusterList = [System.Collections.ArrayList]::new()
foreach ($cg in $allClusters) {
    foreach ($srv in $cg.servers) {
        [void]$clusterList.Add(@{ FQDN = $srv; Type = $cg.cluster_type })
    }
}

Write-Log "START zbierania statusu klastrow ($($clusterList.Count) klastrow)"
$startTime = Get-Date
$clusterResults = [System.Collections.ArrayList]::new()

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

# OPTYMALIZACJA: Równoległe przetwarzanie klastrów jeśli jest ich więcej niż 1
if ($clusterList.Count -eq 1) {
    # Jeden klaster - wykonaj synchronicznie
    $result = & $scriptBlock -clusterFQDN $clusterList[0].FQDN -clusterType $clusterList[0].Type
    if ($result.Success) {
        Write-Log "OK: $($result.ClusterName) ($($result.ClusterType)) - $($result.Nodes.Count) wezlow, $($result.Roles.Count) rol"
    } else {
        Write-Log "FAIL: $($result.FQDN) - $($result.Error)"
    }
    [void]$clusterResults.Add($result)
} else {
    # Wiele klastrów - użyj Start-Job dla równoległości
    $jobs = @()
    foreach ($cluster in $clusterList) {
        $jobs += Start-Job -ScriptBlock $scriptBlock -ArgumentList $cluster.FQDN, $cluster.Type
    }

    # Czekaj na zakończenie wszystkich zadań
    $jobs | Wait-Job | ForEach-Object {
        $result = Receive-Job $_
        Remove-Job $_

        if ($result.Success) {
            Write-Log "OK: $($result.ClusterName) ($($result.ClusterType)) - $($result.Nodes.Count) wezlow, $($result.Roles.Count) rol"
        } else {
            Write-Log "FAIL: $($result.FQDN) - $($result.Error)"
        }
        [void]$clusterResults.Add($result)
    }
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

Write-Log "KONIEC: ${duration}s (OK: $onlineCount, FAIL: $($clusterResults.Count - $onlineCount))"
