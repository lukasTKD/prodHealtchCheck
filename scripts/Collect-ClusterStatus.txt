#Requires -Version 5.1
# =============================================================================
# Collect-ClusterStatus.ps1
# Zbiera status klastrow Windows (SQL, FileShare) oraz serwerow MQ
# Bazuje na sprawdzonym kodzie z old_working_ps\Untitled6.ps1 + MQ_*.ps1
# [PSCustomObject] wszedzie - poprawna serializacja przez PS Remoting
# =============================================================================

$ScriptPath = $PSScriptRoot
$ConfigFile = Join-Path (Split-Path $ScriptPath -Parent) "app-config.json"

if (Test-Path $ConfigFile) {
    $appConfig  = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $DataPath   = $appConfig.paths.dataPath
    $LogsPath   = $appConfig.paths.logsPath
    $ConfigPath = $appConfig.paths.configPath
} else {
    $BasePath   = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
    $DataPath   = "$BasePath\data"
    $LogsPath   = "$BasePath\logs"
    $ConfigPath = "$BasePath\config"
}

@($DataPath, $LogsPath) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

$OutputPath = "$DataPath\infra_ClustersWindows.json"
$LogPath    = "$LogsPath\ServerHealthMonitor.log"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts [CLUSTERS] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

# --- Wczytaj konfiguracje ---
$possiblePaths = @(
    "$ConfigPath\clusters.json",
    "D:\PROD_REPO_DATA\IIS\Cluster\clusters.json"
)
$ClustersConfigPath = $null
foreach ($p in $possiblePaths) {
    if (Test-Path $p) { $ClustersConfigPath = $p; break }
}
if (-not $ClustersConfigPath) {
    Write-Log "BLAD: Brak pliku clusters.json"
    @{ LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); TotalClusters = 0; Clusters = @(); Error = "Brak clusters.json" } |
        ConvertTo-Json -Depth 10 | Out-File $OutputPath -Encoding UTF8 -Force
    exit 1
}

Write-Log "Konfiguracja: $ClustersConfigPath"
$config = Get-Content $ClustersConfigPath -Raw | ConvertFrom-Json

# Konfiguracja MQ serwerow (dla typow MQ - nie sa klastrami Windows)
$MQConfigPath = "$ConfigPath\mq_servers.json"
$mqConfig = if (Test-Path $MQConfigPath) { Get-Content $MQConfigPath -Raw | ConvertFrom-Json } else { $null }

Write-Log "=== START zbierania statusu klastrow ==="
$startTime = Get-Date
$allClusters = [System.Collections.ArrayList]::new()
$processedClusters = @{}

foreach ($clusterDef in $config.clusters) {
    $clusterType = $clusterDef.cluster_type
    $servers     = @($clusterDef.servers)

    Write-Log "Przetwarzam typ=$clusterType, serwery=[$($servers -join ', ')]"

    if ($clusterType -eq "MQ") {
        # =================================================================
        # MQ: NIE sa klastrami Windows - uzywamy dspmq + Get-NetIPAddress
        # Grupujemy wg mq_servers.json
        # =================================================================
        if ($mqConfig) {
            foreach ($grpProp in $mqConfig.PSObject.Properties) {
                $groupName  = $grpProp.Name
                $grpServers = @($grpProp.Value)

                # Tylko serwery ktore sa w clusters.json pod typem MQ
                $relevant = @($grpServers | Where-Object { $_ -in $servers })
                if ($relevant.Count -eq 0) { continue }

                Write-Log "  MQ grupa: $groupName -> $($grpServers -join ', ')"

                $mqNodes = [System.Collections.ArrayList]::new()
                $mqRoles = [System.Collections.ArrayList]::new()
                $groupOK = $false

                foreach ($srv in $grpServers) {
                    # --- Node status: polaczenie + IP ---
                    try {
                        $nodeResult = Invoke-Command -ComputerName $srv -ErrorAction Stop -ScriptBlock {
                            $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                                   Where-Object { $_.IPAddress -like "10.*" -or $_.IPAddress -like "172.*" -or $_.IPAddress -like "192.168.*" } |
                                   Select-Object -First 1).IPAddress
                            [PSCustomObject]@{
                                RealName = $env:COMPUTERNAME
                                IP       = if ($ip) { $ip } else { "N/A" }
                            }
                        }
                        [void]$mqNodes.Add([PSCustomObject]@{
                            Name          = $nodeResult.RealName
                            State         = "Up"
                            NodeWeight    = 1
                            DynamicWeight = 1
                            IPAddresses   = $nodeResult.IP
                        })
                        $groupOK = $true
                    } catch {
                        [void]$mqNodes.Add([PSCustomObject]@{
                            Name          = $srv
                            State         = "Down"
                            NodeWeight    = 1
                            DynamicWeight = 1
                            IPAddresses   = "Brak"
                        })
                        Write-Log "    FAIL node $srv : $($_.Exception.Message)"
                    }

                    # --- QManager status: dspmq + port ---
                    try {
                        $qmResults = Invoke-Command -ComputerName $srv -ErrorAction Stop -ScriptBlock {
                            $results = @()
                            $mqData = dspmq 2>$null
                            if ($mqData) {
                                foreach ($line in $mqData) {
                                    if ($line -match 'QMNAME\s*\(\s*(?<name>.*?)\s*\)\s+STATUS\s*\(\s*(?<state>.*?)\s*\)') {
                                        $qmName   = $Matches['name'].Trim()
                                        $rawState = $Matches['state'].Trim()
                                        $cleanState = $rawState -replace 'Dzia.+?c[ye]', 'Running'

                                        $port = ""
                                        if ($cleanState -match 'Running|Dzia') {
                                            $lsData = "DISPLAY LSSTATUS(*) PORT" | runmqsc $qmName 2>$null
                                            if ($lsData) {
                                                foreach ($l in $lsData) {
                                                    if ($l -match 'PORT\s*\(\s*(?<p>\d+)\s*\)') {
                                                        $port = $Matches['p']; break
                                                    }
                                                }
                                            }
                                        }

                                        $results += [PSCustomObject]@{
                                            Name      = $qmName
                                            State     = $cleanState
                                            OwnerNode = $env:COMPUTERNAME
                                            Port      = $port
                                        }
                                    }
                                }
                            }
                            $results
                        }

                        foreach ($qm in $qmResults) {
                            [void]$mqRoles.Add([PSCustomObject]@{
                                Name        = $qm.Name
                                State       = $qm.State
                                OwnerNode   = $qm.OwnerNode
                                IPAddresses = $qm.Port
                            })
                        }
                    } catch {
                        Write-Log "    FAIL dspmq $srv : $($_.Exception.Message)"
                    }
                }

                [void]$allClusters.Add([PSCustomObject]@{
                    ClusterName = $groupName
                    ClusterType = "MQ"
                    Status      = if ($groupOK) { "Online" } else { "Error" }
                    FQDN        = ($grpServers -join ", ")
                    Nodes       = @($mqNodes)
                    Roles       = @($mqRoles)
                    Error       = $null
                })
                Write-Log "  MQ $groupName : $($mqNodes.Count) wezlow, $($mqRoles.Count) qm"
            }
        } else {
            # Brak mq_servers.json
            foreach ($srv in $servers) {
                [void]$allClusters.Add([PSCustomObject]@{
                    ClusterName = $srv
                    ClusterType = "MQ"
                    Status      = "Error"
                    FQDN        = $srv
                    Nodes       = @()
                    Roles       = @()
                    Error       = "Brak mq_servers.json"
                })
            }
        }

    } else {
        # =================================================================
        # SQL / FileShare: prawdziwe klastry Windows FailoverClustering
        # Wzorzec 1:1 z Untitled6.ps1 (Invoke-Command per serwer)
        # =================================================================
        foreach ($srv in $servers) {
            Write-Log "  Klaster $clusterType : $srv"

            try {
                # Pobierz nazwe klastra
                $actualClusterName = Invoke-Command -ComputerName $srv -ErrorAction Stop -ScriptBlock {
                    (Get-Cluster -ErrorAction Stop).Name
                }

                # Pomijaj duplikaty — ten sam klaster z drugiego wezla
                if ($processedClusters.ContainsKey($actualClusterName)) {
                    Write-Log "    Pomijam $srv (klaster $actualClusterName juz przetworzony)"
                    continue
                }
                $processedClusters[$actualClusterName] = $true

                # Nodes — identycznie jak ClusterNodeStatus() z Untitled6.ps1
                $nodes = Invoke-Command -ComputerName $srv -ErrorAction Stop -ScriptBlock {
                    Get-ClusterNode | ForEach-Object {
                        $node = $_
                        $ips = (Get-ClusterNetworkInterface -Node $node.Name -ErrorAction SilentlyContinue |
                                ForEach-Object { $_.Address }) -join ", "
                        [PSCustomObject]@{
                            Name          = $node.Name
                            State         = $node.State.ToString()
                            NodeWeight    = $node.NodeWeight
                            DynamicWeight = $node.DynamicWeight
                            IPAddresses   = if ($ips) { $ips } else { "N/A" }
                        }
                    }
                }

                # Roles — identycznie jak SQLClusterGroupStatus() z Untitled6.ps1
                $roles = Invoke-Command -ComputerName $srv -ErrorAction Stop -ScriptBlock {
                    Get-ClusterGroup | ForEach-Object {
                        $role = $_
                        $ipAddresses = ""
                        try {
                            $resources = Get-ClusterResource | Where-Object { $_.OwnerGroup -eq $role.Name }
                            $ipAddresses = ($resources | Where-Object { $_.ResourceType -eq "IP Address" } | ForEach-Object {
                                try { (Get-ClusterParameter -InputObject $_ -Name Address).Value } catch { "N/A" }
                            }) -join ", "
                        } catch {
                            $ipAddresses = "N/A"
                        }

                        # Dla rol SQL podmien nazwe na DNS name
                        $displayName = $role.Name
                        if ($role.Name -like "*SQL*" -and $ipAddresses -and $ipAddresses -ne "N/A" -and $ipAddresses -ne "") {
                            $sqlIP = ($ipAddresses -split ", ")[0]
                            if ($sqlIP) {
                                try { $displayName = ([System.Net.Dns]::GetHostEntry($sqlIP)).HostName } catch {}
                            }
                        }

                        [PSCustomObject]@{
                            Name        = $displayName
                            State       = $role.State.ToString()
                            OwnerNode   = $role.OwnerNode.ToString()
                            IPAddresses = $ipAddresses
                        }
                    }
                }

                [void]$allClusters.Add([PSCustomObject]@{
                    ClusterName = $actualClusterName
                    ClusterType = $clusterType
                    Status      = "Online"
                    FQDN        = $srv
                    Nodes       = @($nodes)
                    Roles       = @($roles)
                    Error       = $null
                })
                Write-Log "    OK: $actualClusterName - $(@($nodes).Count) wezlow, $(@($roles).Count) rol"

            } catch {
                Write-Log "    FAIL: $srv - $($_.Exception.Message)"
                [void]$allClusters.Add([PSCustomObject]@{
                    ClusterName = $srv
                    ClusterType = $clusterType
                    Status      = "Error"
                    FQDN        = $srv
                    Nodes       = @()
                    Roles       = @()
                    Error       = $_.Exception.Message
                })
            }
        }
    }
}

# --- Zapisz wynik ---
$duration    = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
$onlineCount = @($allClusters | Where-Object { $_.Status -eq "Online" }).Count

@{
    LastUpdate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $duration
    TotalClusters      = $allClusters.Count
    OnlineCount        = $onlineCount
    FailedCount        = $allClusters.Count - $onlineCount
    Clusters           = @($allClusters)
} | ConvertTo-Json -Depth 10 | Out-File $OutputPath -Encoding UTF8 -Force

Write-Log "=== KONIEC: ${duration}s (OK: $onlineCount, FAIL: $($allClusters.Count - $onlineCount)) ==="
