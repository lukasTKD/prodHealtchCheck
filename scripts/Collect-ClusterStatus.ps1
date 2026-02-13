#Requires -Version 5.1
# =============================================================================
# Collect-ClusterStatus.ps1
# Zbiera status klastrow Windows i zapisuje do JSON
# Uruchamiany co 5 minut (razem z Collect-AllGroups.ps1)
# Logika oparta na dzialajacych skryptach z old_working_ps
# =============================================================================

$ScriptPath = $PSScriptRoot
$ConfigFile = Join-Path (Split-Path $ScriptPath -Parent) "app-config.json"

# Wczytaj konfiguracje
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

# Upewnij sie ze katalogi istnieja
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

# --- Funkcja pobierajaca status wezlow klastra (z Untitled6.ps1) ---
function Get-ClusterNodeStatus {
    param([string]$ClusterName)

    try {
        $result = Invoke-Command -ComputerName $ClusterName -ErrorAction Stop -ScriptBlock {
            Get-ClusterNode | ForEach-Object {
                $node = $_
                $nodeNetworks = Get-ClusterNetworkInterface -Node $node.Name -ErrorAction SilentlyContinue
                $ipAddresses = ($nodeNetworks | ForEach-Object { $_.Address }) -join ", "

                [PSCustomObject]@{
                    Name          = $node.Name
                    State         = $node.State.ToString()
                    NodeWeight    = $node.NodeWeight
                    DynamicWeight = $node.DynamicWeight
                    IPAddresses   = if ($ipAddresses) { $ipAddresses } else { "N/A" }
                }
            }
        }
        return $result
    }
    catch {
        Write-Log "BLAD Get-ClusterNodeStatus dla $ClusterName : $($_.Exception.Message)"
        return $null
    }
}

# --- Funkcja pobierajaca role klastra (z Untitled6.ps1) ---
function Get-ClusterRoleStatus {
    param([string]$ClusterName)

    try {
        $result = Invoke-Command -ComputerName $ClusterName -ErrorAction Stop -ScriptBlock {
            Get-ClusterGroup | ForEach-Object {
                $role = $_
                try {
                    $resources = Get-ClusterResource | Where-Object { $_.OwnerGroup -eq $role.Name }
                    $ipAddresses = ($resources | Where-Object { $_.ResourceType -eq "IP Address" } | ForEach-Object {
                        try {
                            $params = Get-ClusterParameter -InputObject $_ -Name Address -ErrorAction SilentlyContinue
                            $params.Value
                        } catch { "N/A" }
                    }) -join ", "
                } catch {
                    $ipAddresses = "N/A"
                }

                [PSCustomObject]@{
                    Name        = $role.Name
                    State       = $role.State.ToString()
                    OwnerNode   = $role.OwnerNode.ToString()
                    IPAddresses = if ($ipAddresses) { $ipAddresses } else { "" }
                }
            }
        }
        return $result
    }
    catch {
        Write-Log "BLAD Get-ClusterRoleStatus dla $ClusterName : $($_.Exception.Message)"
        return $null
    }
}

# --- Funkcja pobierajaca nazwe klastra ---
function Get-ClusterDisplayName {
    param([string]$ClusterName)

    try {
        $result = Invoke-Command -ComputerName $ClusterName -ErrorAction Stop -ScriptBlock {
            (Get-Cluster).Name
        }
        return $result
    }
    catch {
        return $ClusterName
    }
}

# --- Wczytaj konfiguracje klastrow ---
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
    @{
        LastUpdate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CollectionDuration = 0
        TotalClusters      = 0
        OnlineCount        = 0
        FailedCount        = 0
        Clusters           = @()
        Error              = "Brak pliku konfiguracji clusters.json"
    } | ConvertTo-Json -Depth 10 | Out-File $OutputPath -Encoding UTF8 -Force
    exit 1
}

Write-Log "Uzywam konfiguracji: $ClustersConfigPath"

try {
    $configRaw = Get-Content $ClustersConfigPath -Raw
    $config = $configRaw | ConvertFrom-Json
} catch {
    Write-Log "BLAD: Nie mozna sparsowac clusters.json - $($_.Exception.Message)"
    exit 1
}

# Obsluga obu formatow konfiguracji: clusterNames (plaska tablica) lub clusters (tablica obiektow)
$clusterList = @()
if ($config.clusterNames) {
    # Format: { "clusterNames": ["srv1", "srv2"] }
    $clusterList = @($config.clusterNames)
    Write-Log "Uzyto formatu clusterNames: $($clusterList.Count) klastrow"
} elseif ($config.clusters) {
    # Format: { "clusters": [{ "cluster_type": "SQL", "servers": ["srv1", "srv2"] }] }
    foreach ($cluster in $config.clusters) {
        if ($cluster.servers) {
            $clusterList += @($cluster.servers)
        }
    }
    $clusterList = @($clusterList | Select-Object -Unique)
    Write-Log "Uzyto formatu clusters: $($clusterList.Count) klastrow"
}

if ($clusterList.Count -eq 0) {
    Write-Log "BLAD: Brak klastrow w konfiguracji"
    exit 1
}

Write-Log "START zbierania statusu klastrow ($($clusterList.Count) klastrow)"
$startTime = Get-Date
$clusterResults = [System.Collections.ArrayList]::new()

# --- Zbieranie danych z klastrow ---
foreach ($clusterServer in $clusterList) {
    Write-Log "Odpytuje klaster: $clusterServer"

    try {
        # Pobierz nazwe klastra
        $clusterDisplayName = Get-ClusterDisplayName -ClusterName $clusterServer

        # Pobierz wezly
        $nodes = @(Get-ClusterNodeStatus -ClusterName $clusterServer)

        # Pobierz role
        $roles = @(Get-ClusterRoleStatus -ClusterName $clusterServer)

        if ($null -eq $nodes -or $nodes.Count -eq 0) {
            throw "Nie udalo sie pobrac wezlow klastra"
        }

        # Okresl typ klastra na podstawie rol
        $clusterType = "Windows"
        if ($roles | Where-Object { $_.Name -like "*SQL*" }) {
            $clusterType = "SQL"
        } elseif ($roles | Where-Object { $_.Name -like "*File*" -or $_.Name -like "*Share*" }) {
            $clusterType = "FileShare"
        } elseif ($roles | Where-Object { $_.Name -like "*QM*" -or $_.Name -like "*MQ*" }) {
            $clusterType = "MQ"
        }

        $result = @{
            Success     = $true
            ClusterName = $clusterDisplayName
            FQDN        = $clusterServer
            ClusterType = $clusterType
            Status      = "Online"
            Nodes       = @($nodes | ForEach-Object {
                @{
                    Name          = $_.Name
                    State         = $_.State
                    NodeWeight    = $_.NodeWeight
                    DynamicWeight = $_.DynamicWeight
                    IPAddresses   = $_.IPAddresses
                }
            })
            Roles       = @($roles | ForEach-Object {
                @{
                    Name        = $_.Name
                    State       = $_.State
                    OwnerNode   = $_.OwnerNode
                    IPAddresses = $_.IPAddresses
                }
            })
            Error       = $null
        }

        Write-Log "OK: $clusterDisplayName ($clusterType) - $($nodes.Count) wezlow, $($roles.Count) rol"
        [void]$clusterResults.Add($result)
    }
    catch {
        $errMsg = $_.Exception.Message
        Write-Log "FAIL: $clusterServer - $errMsg"
        [void]$clusterResults.Add(@{
            Success     = $false
            ClusterName = $clusterServer
            FQDN        = $clusterServer
            ClusterType = "Unknown"
            Status      = "Error"
            Nodes       = @()
            Roles       = @()
            Error       = $errMsg
        })
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
