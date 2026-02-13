#Requires -Version 5.1
# =============================================================================
# Collect-ClusterStatus.ps1
# Zbiera status klastrow Windows (wezly + role) - zapis do JSON
# Bazuje na dzialajacym kodzie z old_working_ps/Untitled6.ps1
# =============================================================================

$ScriptPath = $PSScriptRoot
$ConfigFile = Join-Path (Split-Path $ScriptPath -Parent) "app-config.json"

if (Test-Path $ConfigFile) {
    $appConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $DataPath = $appConfig.paths.dataPath
    $LogsPath = $appConfig.paths.logsPath
    $ConfigPath = $appConfig.paths.configPath
} else {
    $BasePath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
    $DataPath = "$BasePath\data"
    $LogsPath = "$BasePath\logs"
    $ConfigPath = "$BasePath\config"
}

$OutputPath = "$DataPath\infra_ClustersWindows.json"
$LogPath = "$LogsPath\ServerHealthMonitor.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [CLUSTERS] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

# --- Funkcje z Untitled6.ps1 ---
function ClusterNodeStatus($cluster) {
    Invoke-Command -ComputerName $cluster -ScriptBlock {
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
}

function ClusterGroupStatus($cluster) {
    Invoke-Command -ComputerName $cluster -ScriptBlock {
        Get-ClusterGroup | ForEach-Object {
            $role = $_
            try {
                $resources = Get-ClusterResource | Where-Object { $_.OwnerGroup -eq $role.Name }
                $ipAddresses = ($resources | Where-Object { $_.ResourceType -eq "IP Address" } | ForEach-Object {
                    try {
                        $params = Get-ClusterParameter -InputObject $_ -Name Address
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
}

function GetClusterName($cluster) {
    Invoke-Command -ComputerName $cluster -ScriptBlock {
        (Get-Cluster).Name
    }
}

# --- Wczytaj konfiguracje ---
$ClustersConfigPath = "$ConfigPath\clusters.json"
if (-not (Test-Path $ClustersConfigPath)) {
    $ClustersConfigPath = "D:\PROD_REPO_DATA\IIS\Cluster\clusters.json"
}

if (-not (Test-Path $ClustersConfigPath)) {
    Write-Log "BLAD: Brak pliku clusters.json"
    @{
        LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        TotalClusters = 0
        Clusters = @()
        Error = "Brak pliku konfiguracji"
    } | ConvertTo-Json -Depth 10 | Out-File $OutputPath -Encoding UTF8
    exit 1
}

$config = Get-Content $ClustersConfigPath -Raw | ConvertFrom-Json

# Wyciagnij wszystkie serwery z konfiguracji
$clusterList = @()
foreach ($c in $config.clusters) {
    foreach ($srv in $c.servers) {
        $clusterList += @{ Server = $srv; Type = $c.cluster_type }
    }
}

Write-Log "START: $($clusterList.Count) klastrow"
$startTime = Get-Date
$results = [System.Collections.ArrayList]::new()

# --- Rownolegle odpytywanie klastrow ---
$jobs = @()
foreach ($item in $clusterList) {
    $jobs += Start-Job -ScriptBlock {
        param($srv, $type)

        function ClusterNodeStatus($cluster) {
            Invoke-Command -ComputerName $cluster -ScriptBlock {
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
        }

        function ClusterGroupStatus($cluster) {
            Invoke-Command -ComputerName $cluster -ScriptBlock {
                Get-ClusterGroup | ForEach-Object {
                    $role = $_
                    try {
                        $resources = Get-ClusterResource | Where-Object { $_.OwnerGroup -eq $role.Name }
                        $ipAddresses = ($resources | Where-Object { $_.ResourceType -eq "IP Address" } | ForEach-Object {
                            try {
                                $params = Get-ClusterParameter -InputObject $_ -Name Address
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
        }

        function GetClusterName($cluster) {
            Invoke-Command -ComputerName $cluster -ScriptBlock {
                (Get-Cluster).Name
            }
        }

        try {
            $clusterName = GetClusterName -cluster $srv
            $nodes = @(ClusterNodeStatus -cluster $srv)
            $roles = @(ClusterGroupStatus -cluster $srv)

            @{
                Success     = $true
                ClusterName = $clusterName
                FQDN        = $srv
                ClusterType = $type
                Status      = "Online"
                Nodes       = $nodes
                Roles       = $roles
                Error       = $null
            }
        } catch {
            @{
                Success     = $false
                ClusterName = $srv
                FQDN        = $srv
                ClusterType = $type
                Status      = "Error"
                Nodes       = @()
                Roles       = @()
                Error       = $_.Exception.Message
            }
        }
    } -ArgumentList $item.Server, $item.Type
}

# Czekaj na wszystkie joby (max 30 sekund)
$jobs | Wait-Job -Timeout 30 | Out-Null

foreach ($job in $jobs) {
    if ($job.State -eq 'Completed') {
        $result = Receive-Job -Job $job
        [void]$results.Add($result)
        Write-Log "OK: $($result.ClusterName) ($($result.ClusterType))"
    } else {
        Write-Log "TIMEOUT: job $($job.Id)"
    }
    Remove-Job -Job $job -Force
}

$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
$onlineCount = @($results | Where-Object { $_.Status -eq "Online" }).Count

$output = @{
    LastUpdate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $duration
    TotalClusters      = $results.Count
    OnlineCount        = $onlineCount
    FailedCount        = $results.Count - $onlineCount
    Clusters           = @($results)
}

$output | ConvertTo-Json -Depth 10 | Out-File $OutputPath -Encoding UTF8 -Force
Write-Log "KONIEC: ${duration}s (OK: $onlineCount, FAIL: $($results.Count - $onlineCount))"
