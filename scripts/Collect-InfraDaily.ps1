#Requires -Version 5.1
# =============================================================================
# Collect-InfraDaily.ps1
# Zbiera: udzialy sieciowe (FileShare), instancje SQL, kolejki MQ
# Pobiera dane bezposrednio z klastrow - zapis do JSON
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

$LogPath = "$LogsPath\ServerHealthMonitor.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [INFRA] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

Write-Log "=== START Collect-InfraDaily ==="
$globalStart = Get-Date

# Wczytaj konfiguracje klastrow
$ClustersConfigPath = "$ConfigPath\clusters.json"
if (-not (Test-Path $ClustersConfigPath)) {
    $ClustersConfigPath = "D:\PROD_REPO_DATA\IIS\Cluster\clusters.json"
}

$clustersConfig = $null
if (Test-Path $ClustersConfigPath) {
    $clustersConfig = Get-Content $ClustersConfigPath -Raw | ConvertFrom-Json
}

# Wczytaj konfiguracje MQ
$MQConfigPath = "$ConfigPath\mq_servers.json"
$mqConfig = $null
if (Test-Path $MQConfigPath) {
    $mqConfig = Get-Content $MQConfigPath -Raw | ConvertFrom-Json
}

# ===================================================================
# UDZIALY SIECIOWE (z klastrow FileShare)
# ===================================================================
Write-Log "--- Udzialy sieciowe ---"
$startShares = Get-Date
$shareResults = [System.Collections.ArrayList]::new()

if ($clustersConfig) {
    $fileShareClusters = @($clustersConfig.clusters | Where-Object { $_.cluster_type -eq "FileShare" })

    foreach ($cluster in $fileShareClusters) {
        foreach ($srv in $cluster.servers) {
            Write-Log "FileShare: $srv"
            try {
                $shares = Get-SmbShare -CimSession $srv -Special $false -ErrorAction Stop
                $shareList = @($shares | ForEach-Object {
                    @{
                        ShareName  = $_.Name
                        SharePath  = $_.Path
                        ShareState = "Online"
                    }
                })
                [void]$shareResults.Add(@{
                    ServerName = $srv
                    ShareCount = $shareList.Count
                    Shares     = $shareList
                    Error      = $null
                })
                Write-Log "OK FileShare: $srv ($($shareList.Count) udzialow)"
            } catch {
                Write-Log "FAIL FileShare: $srv - $($_.Exception.Message)"
                [void]$shareResults.Add(@{
                    ServerName = $srv
                    ShareCount = 0
                    Shares     = @()
                    Error      = $_.Exception.Message
                })
            }
        }
    }
}

$sharesDuration = [math]::Round(((Get-Date) - $startShares).TotalSeconds, 1)
@{
    LastUpdate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $sharesDuration
    TotalServers       = $shareResults.Count
    FileServers        = @($shareResults)
} | ConvertTo-Json -Depth 10 | Out-File "$DataPath\infra_UdzialySieciowe.json" -Encoding UTF8 -Force
Write-Log "Udzialy zapisane (${sharesDuration}s)"

# ===================================================================
# INSTANCJE SQL (z klastrow SQL)
# ===================================================================
Write-Log "--- Instancje SQL ---"
$startSQL = Get-Date
$sqlResults = [System.Collections.ArrayList]::new()

if ($clustersConfig) {
    $sqlClusters = @($clustersConfig.clusters | Where-Object { $_.cluster_type -eq "SQL" })

    foreach ($cluster in $sqlClusters) {
        foreach ($srv in $cluster.servers) {
            Write-Log "SQL: $srv"
            try {
                $result = Invoke-Command -ComputerName $srv -ErrorAction Stop -ScriptBlock {
                    $databases = @()
                    $sqlVersion = "N/A"
                    $edition = "N/A"

                    # Pobierz info o bazach z Availability Groups
                    try {
                        $ags = Get-ClusterResource | Where-Object { $_.ResourceType -eq 'SQL Server Availability Group' }
                        foreach ($ag in $ags) {
                            $ownerNode = $ag.OwnerNode
                            $agDbs = Invoke-Sqlcmd -Query "SELECT database_name FROM sys.dm_hadr_database_replica_cluster_states" -ServerInstance $ownerNode -ErrorAction SilentlyContinue
                            foreach ($db in $agDbs) {
                                $databases += @{
                                    DatabaseName = $db.database_name
                                    State        = "ONLINE"
                                    AGName       = $ag.Name
                                }
                            }
                        }
                    } catch {}

                    # Pobierz wersje SQL
                    try {
                        $ver = Invoke-Sqlcmd -Query "SELECT @@VERSION as Ver" -ServerInstance $env:COMPUTERNAME -ErrorAction SilentlyContinue
                        if ($ver) { $sqlVersion = ($ver.Ver -split '\n')[0] }
                    } catch {}

                    @{
                        Databases  = $databases
                        SQLVersion = $sqlVersion
                        Edition    = $edition
                    }
                }

                [void]$sqlResults.Add(@{
                    ServerName    = $srv
                    SQLVersion    = $result.SQLVersion
                    Edition       = $result.Edition
                    DatabaseCount = $result.Databases.Count
                    Databases     = @($result.Databases)
                    Error         = $null
                })
                Write-Log "OK SQL: $srv ($($result.Databases.Count) baz)"
            } catch {
                Write-Log "FAIL SQL: $srv - $($_.Exception.Message)"
                [void]$sqlResults.Add(@{
                    ServerName    = $srv
                    SQLVersion    = "N/A"
                    Edition       = "N/A"
                    DatabaseCount = 0
                    Databases     = @()
                    Error         = $_.Exception.Message
                })
            }
        }
    }
}

$sqlDuration = [math]::Round(((Get-Date) - $startSQL).TotalSeconds, 1)
@{
    LastUpdate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $sqlDuration
    TotalInstances     = $sqlResults.Count
    Instances          = @($sqlResults)
} | ConvertTo-Json -Depth 10 | Out-File "$DataPath\infra_InstancjeSQL.json" -Encoding UTF8 -Force
Write-Log "SQL zapisane (${sqlDuration}s)"

# ===================================================================
# KOLEJKI MQ (z mq_servers.json)
# ===================================================================
Write-Log "--- Kolejki MQ ---"
$startMQ = Get-Date
$mqResults = [System.Collections.ArrayList]::new()

if ($mqConfig) {
    # Zbierz liste serwerow MQ
    $mqServers = @()
    foreach ($prop in $mqConfig.PSObject.Properties) {
        $clusterName = $prop.Name
        foreach ($srv in $prop.Value) {
            $mqServers += @{ Server = $srv; Cluster = $clusterName }
        }
    }

    Write-Log "MQ: $($mqServers.Count) serwerow"

    # Odpytaj rownolegle
    $serverNames = @($mqServers | ForEach-Object { $_.Server })

    $mqScriptBlock = {
        $qmgrResults = @()
        try {
            $mqData = dspmq 2>$null
            if ($mqData) {
                foreach ($line in $mqData) {
                    if ($line -match 'QMNAME\s*\(\s*(?<name>.*?)\s*\)\s+STATUS\s*\(\s*(?<state>.*?)\s*\)') {
                        $qmName = $Matches['name'].Trim()
                        $rawState = $Matches['state'].Trim()
                        $cleanState = $rawState -replace 'Dzia.+?c[ye]', 'Running'

                        $Port = ""
                        $queues = @()

                        if ($cleanState -match 'Running|Dzia') {
                            try {
                                $listenerData = "DISPLAY LSSTATUS(*) PORT" | runmqsc $qmName 2>$null
                                foreach ($lLine in $listenerData) {
                                    if ($lLine -match 'PORT\s*\(\s*(?<p>\d+)\s*\)') {
                                        $Port = $Matches['p']
                                        break
                                    }
                                }
                            } catch {}

                            try {
                                $queueOutput = "DISPLAY QLOCAL(*)" | runmqsc $qmName 2>$null
                                foreach ($qLine in $queueOutput) {
                                    if ($qLine -match 'QUEUE\s*\(\s*(?<qname>.*?)\s*\)') {
                                        $qName = $Matches['qname'].Trim()
                                        if ($qName -notmatch '^SYSTEM\.|^AMQ\.') {
                                            $queues += @{ QueueName = $qName }
                                        }
                                    }
                                }
                            } catch {}
                        }

                        $qmgrResults += @{
                            QueueManager = $qmName
                            Status       = $cleanState
                            Port         = $Port
                            QueueCount   = $queues.Count
                            Queues       = $queues
                        }
                    }
                }
            }
        } catch {}

        @{
            ServerName    = $env:COMPUTERNAME
            QueueManagers = $qmgrResults
        }
    }

    $mqRaw = Invoke-Command -ComputerName $serverNames -ScriptBlock $mqScriptBlock -ErrorAction SilentlyContinue

    foreach ($r in $mqRaw) {
        $srvInfo = $mqServers | Where-Object { $_.Server -eq $r.PSComputerName } | Select-Object -First 1
        [void]$mqResults.Add(@{
            ServerName    = $r.ServerName
            Description   = if ($srvInfo) { $srvInfo.Cluster } else { "" }
            QueueManagers = @($r.QueueManagers)
            Error         = $null
        })
        Write-Log "OK MQ: $($r.ServerName)"
    }

    # Serwery niedostepne
    $okServers = @($mqRaw | ForEach-Object { $_.PSComputerName })
    foreach ($srv in $serverNames) {
        if ($srv -notin $okServers) {
            $srvInfo = $mqServers | Where-Object { $_.Server -eq $srv } | Select-Object -First 1
            [void]$mqResults.Add(@{
                ServerName    = $srv
                Description   = if ($srvInfo) { $srvInfo.Cluster } else { "" }
                QueueManagers = @()
                Error         = "Niedostepny"
            })
            Write-Log "FAIL MQ: $srv"
        }
    }
}

$mqDuration = [math]::Round(((Get-Date) - $startMQ).TotalSeconds, 1)
@{
    LastUpdate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $mqDuration
    TotalServers       = $mqResults.Count
    Servers            = @($mqResults)
} | ConvertTo-Json -Depth 10 | Out-File "$DataPath\infra_KolejkiMQ.json" -Encoding UTF8 -Force
Write-Log "MQ zapisane (${mqDuration}s)"

# ===================================================================
$globalDuration = [math]::Round(((Get-Date) - $globalStart).TotalSeconds, 1)
Write-Log "=== KONIEC Collect-InfraDaily (${globalDuration}s) ==="
