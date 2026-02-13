# Collect-ClusterStatus.ps1
# Zbiera status klastrow Windows (SQL, FileShare) i zapisuje do osobnych plikow JSON
# - infra_ClustersSQL.json
# - infra_ClustersFileShare.json

# --- SCIEZKI ---
$ScriptDir  = Split-Path $PSScriptRoot -Parent
$appConfig  = [System.IO.File]::ReadAllText("$ScriptDir\app-config.json") | ConvertFrom-Json
$DataPath   = $appConfig.paths.dataPath
$ConfigPath = $appConfig.paths.configPath
$LogsPath   = $appConfig.paths.logsPath

# Pliki wyjsciowe z konfiguracji
$SqlOutputFile    = Join-Path $DataPath $appConfig.outputs.clusters.sql
$FShareOutputFile = Join-Path $DataPath $appConfig.outputs.clusters.fileShare

if (!(Test-Path $DataPath))  { New-Item -ItemType Directory -Path $DataPath  -Force | Out-Null }
if (!(Test-Path $LogsPath))  { New-Item -ItemType Directory -Path $LogsPath  -Force | Out-Null }

$LogFile = "$LogsPath\ServerHealthMonitor.log"

function Log($msg) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [CLUSTERS] $msg" | Out-File $LogFile -Append -Encoding UTF8 }

Log "START"
$StartTime = Get-Date

# --- KONFIGURACJA ---
$clustersJson = [System.IO.File]::ReadAllText("$ConfigPath\clusters.json") | ConvertFrom-Json

# Przygotuj struktury dla roznych typow klastrow
$sqlClusters = @()
$fshareClusters = @()
$done = @{}

# ==========================================
# SQL i FileShare — klastry Windows
# ==========================================
foreach ($def in ($clustersJson.clusters | Where-Object { $_.cluster_type -in @("SQL", "FileShare") })) {
    $type = $def.cluster_type

    foreach ($srv in $def.servers) {
        Log "  Klaster $type : $srv"
        try {
            # Pobierz nazwe klastra
            $cluster     = Get-Cluster -Name $srv -ErrorAction Stop
            $clusterName = $cluster.Name

            # Duplikat? (ten sam klaster z drugiego wezla)
            if ($done[$clusterName]) { Log "    Pomijam (duplikat $clusterName)"; continue }
            $done[$clusterName] = $true

            # Wezly
            $nodes = @(Get-ClusterNode -Cluster $srv -ErrorAction Stop | ForEach-Object {
                $node = $_
                try {
                    $nodeNetworks = Get-ClusterNetworkInterface -Cluster $srv -Node $node.Name
                    $ipAddresses  = ($nodeNetworks | ForEach-Object { $_.Address }) -join ", "
                } catch {
                    $ipAddresses = "N/A"
                }
                [PSCustomObject]@{
                    Name        = $node.Name
                    State       = $node.State.ToString()
                    IPAddresses = if ($ipAddresses) { $ipAddresses } else { "N/A" }
                }
            })

            # Role
            $roles = @(Get-ClusterGroup -Cluster $srv -ErrorAction Stop | ForEach-Object {
                $role = $_
                try {
                    $resources = Get-ClusterResource -Cluster $srv | Where-Object { $_.OwnerGroup -eq $role.Name }
                    $ipAddr    = ($resources | Where-Object { $_.ResourceType -eq "IP Address" } | ForEach-Object {
                        try { (Get-ClusterParameter -InputObject $_ -Name Address).Value } catch { "N/A" }
                    }) -join ", "
                } catch { $ipAddr = "N/A" }

                # DNS dla rol SQL
                $displayName = $role.Name
                if ($role.Name -like "*SQL*" -and $ipAddr -and $ipAddr -ne "N/A" -and $ipAddr -ne "") {
                    $sqlIP = ($ipAddr -split ", ")[0]
                    try { $displayName = ([System.Net.Dns]::GetHostEntry($sqlIP)).HostName } catch {}
                }

                [PSCustomObject]@{
                    Name        = $displayName
                    State       = $role.State.ToString()
                    OwnerNode   = $role.OwnerNode.ToString()
                    IPAddresses = if ($ipAddr) { $ipAddr } else { "N/A" }
                }
            })

            $clusterObj = [PSCustomObject]@{
                ClusterName = $clusterName
                ClusterType = $type
                Error       = $null
                Nodes       = $nodes
                Roles       = $roles
            }

            # Dodaj do odpowiedniej kolekcji
            if ($type -eq "SQL") {
                $sqlClusters += $clusterObj
            } elseif ($type -eq "FileShare") {
                $fshareClusters += $clusterObj
            }

            Log "    OK: $clusterName ($($nodes.Count) wezlow, $($roles.Count) rol)"

        } catch {
            $clusterObj = [PSCustomObject]@{
                ClusterName = $srv
                ClusterType = $type
                Error       = $_.Exception.Message
                Nodes       = @()
                Roles       = @()
            }

            if ($type -eq "SQL") {
                $sqlClusters += $clusterObj
            } elseif ($type -eq "FileShare") {
                $fshareClusters += $clusterObj
            }

            Log "    FAIL: $($_.Exception.Message)"
        }
    }
}

$EndTime = Get-Date
$Duration = [math]::Round(($EndTime - $StartTime).TotalSeconds, 1)

# --- ZAPIS SQL ---
if ($sqlClusters.Count -gt 0) {
    $sqlOnline = @($sqlClusters | Where-Object { -not $_.Error }).Count

    @{
        LastUpdate         = $EndTime.ToString("yyyy-MM-dd HH:mm:ss")
        CollectionDuration = $Duration.ToString()
        TotalClusters      = $sqlClusters.Count
        OnlineCount        = $sqlOnline
        FailedCount        = $sqlClusters.Count - $sqlOnline
        Clusters           = $sqlClusters
    } | ConvertTo-Json -Depth 10 | Out-File $SqlOutputFile -Encoding UTF8 -Force

    Log "Zapisano SQL: $SqlOutputFile ($($sqlClusters.Count) klastrow)"
}

# --- ZAPIS FileShare ---
if ($fshareClusters.Count -gt 0) {
    $fshareOnline = @($fshareClusters | Where-Object { -not $_.Error }).Count

    @{
        LastUpdate         = $EndTime.ToString("yyyy-MM-dd HH:mm:ss")
        CollectionDuration = $Duration.ToString()
        TotalClusters      = $fshareClusters.Count
        OnlineCount        = $fshareOnline
        FailedCount        = $fshareClusters.Count - $fshareOnline
        Clusters           = $fshareClusters
    } | ConvertTo-Json -Depth 10 | Out-File $FShareOutputFile -Encoding UTF8 -Force

    Log "Zapisano FileShare: $FShareOutputFile ($($fshareClusters.Count) klastrow)"
}

$totalClusters = $sqlClusters.Count + $fshareClusters.Count
Log "KONIEC: $totalClusters klastrow w ${Duration}s (SQL: $($sqlClusters.Count), FileShare: $($fshareClusters.Count))"
