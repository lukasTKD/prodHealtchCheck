#Requires -Version 5.1
# =============================================================================
# Collect-InfraDaily.ps1
# Zbiera: udzialy sieciowe, instancje SQL, kolejki MQ - SZYBKA WERSJA
# Jedno Invoke-Command na liste serwerow = natywna rownoleglość
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

# Wczytaj konfiguracje
$ClustersConfigPath = "$ConfigPath\clusters.json"
if (-not (Test-Path $ClustersConfigPath)) { $ClustersConfigPath = "D:\PROD_REPO_DATA\IIS\Cluster\clusters.json" }
$clustersConfig = if (Test-Path $ClustersConfigPath) { Get-Content $ClustersConfigPath -Raw | ConvertFrom-Json } else { $null }

$MQConfigPath = "$ConfigPath\mq_servers.json"
$mqConfig = if (Test-Path $MQConfigPath) { Get-Content $MQConfigPath -Raw | ConvertFrom-Json } else { $null }

# ===================================================================
# UDZIALY SIECIOWE (FileShare) - jedno odpytanie
# ===================================================================
Write-Log "--- Udzialy sieciowe ---"
$startShares = Get-Date
$shareResults = [System.Collections.ArrayList]::new()

if ($clustersConfig) {
    $fsServers = @($clustersConfig.clusters | Where-Object { $_.cluster_type -eq "FileShare" } | ForEach-Object { $_.servers } | ForEach-Object { $_ })

    if ($fsServers.Count -gt 0) {
        Write-Log "FileShare: $($fsServers -join ', ')"
        $fsRaw = Invoke-Command -ComputerName $fsServers -ErrorAction SilentlyContinue -ScriptBlock {
            $shares = @(Get-SmbShare -Special $false -ErrorAction SilentlyContinue | ForEach-Object {
                @{ ShareName = $_.Name; SharePath = $_.Path; ShareState = "Online" }
            })
            @{ ServerName = $env:COMPUTERNAME; Shares = $shares }
        }

        foreach ($r in $fsRaw) {
            [void]$shareResults.Add(@{
                ServerName = $r.ServerName
                ShareCount = $r.Shares.Count
                Shares     = @($r.Shares)
                Error      = $null
            })
            Write-Log "OK FileShare: $($r.ServerName) ($($r.Shares.Count))"
        }

        $okFS = @($fsRaw | ForEach-Object { $_.PSComputerName })
        foreach ($srv in $fsServers) {
            if ($srv -notin $okFS) {
                [void]$shareResults.Add(@{ ServerName = $srv; ShareCount = 0; Shares = @(); Error = "Niedostepny" })
                Write-Log "FAIL FileShare: $srv"
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
Write-Log "Udzialy: ${sharesDuration}s"

# ===================================================================
# INSTANCJE SQL - jedno odpytanie
# ===================================================================
Write-Log "--- Instancje SQL ---"
$startSQL = Get-Date
$sqlResults = [System.Collections.ArrayList]::new()

if ($clustersConfig) {
    $sqlServers = @($clustersConfig.clusters | Where-Object { $_.cluster_type -eq "SQL" } | ForEach-Object { $_.servers } | ForEach-Object { $_ })

    if ($sqlServers.Count -gt 0) {
        Write-Log "SQL: $($sqlServers -join ', ')"
        $sqlRaw = Invoke-Command -ComputerName $sqlServers -ErrorAction SilentlyContinue -ScriptBlock {
            $databases = @()
            $sqlVersion = "N/A"

            try {
                $ags = Get-ClusterResource -ErrorAction SilentlyContinue | Where-Object { $_.ResourceType -eq 'SQL Server Availability Group' }
                foreach ($ag in $ags) {
                    $dbs = Invoke-Sqlcmd -Query "SELECT database_name FROM sys.dm_hadr_database_replica_cluster_states" -ServerInstance $ag.OwnerNode -ErrorAction SilentlyContinue
                    foreach ($db in $dbs) {
                        $databases += @{ DatabaseName = $db.database_name; State = "ONLINE"; AGName = $ag.Name }
                    }
                }
            } catch {}

            try {
                $ver = Invoke-Sqlcmd -Query "SELECT @@VERSION as Ver" -ServerInstance $env:COMPUTERNAME -ErrorAction SilentlyContinue
                if ($ver) { $sqlVersion = ($ver.Ver -split '\n')[0] }
            } catch {}

            @{ ServerName = $env:COMPUTERNAME; Databases = $databases; SQLVersion = $sqlVersion }
        }

        foreach ($r in $sqlRaw) {
            [void]$sqlResults.Add(@{
                ServerName    = $r.ServerName
                SQLVersion    = $r.SQLVersion
                DatabaseCount = $r.Databases.Count
                Databases     = @($r.Databases)
                Error         = $null
            })
            Write-Log "OK SQL: $($r.ServerName) ($($r.Databases.Count) baz)"
        }

        $okSQL = @($sqlRaw | ForEach-Object { $_.PSComputerName })
        foreach ($srv in $sqlServers) {
            if ($srv -notin $okSQL) {
                [void]$sqlResults.Add(@{ ServerName = $srv; SQLVersion = "N/A"; DatabaseCount = 0; Databases = @(); Error = "Niedostepny" })
                Write-Log "FAIL SQL: $srv"
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
Write-Log "SQL: ${sqlDuration}s"

# ===================================================================
# KOLEJKI MQ - jedno odpytanie
# ===================================================================
Write-Log "--- Kolejki MQ ---"
$startMQ = Get-Date
$mqResults = [System.Collections.ArrayList]::new()

if ($mqConfig) {
    $mqMap = @{}
    foreach ($prop in $mqConfig.PSObject.Properties) {
        foreach ($srv in $prop.Value) { $mqMap[$srv] = $prop.Name }
    }
    $mqServers = @($mqMap.Keys)

    if ($mqServers.Count -gt 0) {
        Write-Log "MQ: $($mqServers -join ', ')"
        $mqRaw = Invoke-Command -ComputerName $mqServers -ErrorAction SilentlyContinue -ScriptBlock {
            $qmgrs = @()
            $mqData = dspmq 2>$null
            if ($mqData) {
                foreach ($line in $mqData) {
                    if ($line -match 'QMNAME\s*\(\s*(?<name>.*?)\s*\)\s+STATUS\s*\(\s*(?<state>.*?)\s*\)') {
                        $qmName = $Matches['name'].Trim()
                        $state = $Matches['state'].Trim() -replace 'Dzia.+?c[ye]', 'Running'
                        $port = ""
                        $queues = @()

                        if ($state -match 'Running|Dzia') {
                            $lsData = "DISPLAY LSSTATUS(*) PORT" | runmqsc $qmName 2>$null
                            foreach ($l in $lsData) { if ($l -match 'PORT\s*\(\s*(?<p>\d+)\s*\)') { $port = $Matches['p']; break } }

                            $qData = "DISPLAY QLOCAL(*)" | runmqsc $qmName 2>$null
                            foreach ($q in $qData) {
                                if ($q -match 'QUEUE\s*\(\s*(?<qn>.*?)\s*\)') {
                                    $qn = $Matches['qn'].Trim()
                                    if ($qn -notmatch '^SYSTEM\.|^AMQ\.') { $queues += @{ QueueName = $qn } }
                                }
                            }
                        }
                        $qmgrs += @{ QueueManager = $qmName; Status = $state; Port = $port; QueueCount = $queues.Count; Queues = $queues }
                    }
                }
            }
            @{ ServerName = $env:COMPUTERNAME; QueueManagers = $qmgrs }
        }

        foreach ($r in $mqRaw) {
            [void]$mqResults.Add(@{
                ServerName    = $r.ServerName
                Description   = $mqMap[$r.PSComputerName]
                QueueManagers = @($r.QueueManagers)
                Error         = $null
            })
            Write-Log "OK MQ: $($r.ServerName)"
        }

        $okMQ = @($mqRaw | ForEach-Object { $_.PSComputerName })
        foreach ($srv in $mqServers) {
            if ($srv -notin $okMQ) {
                [void]$mqResults.Add(@{ ServerName = $srv; Description = $mqMap[$srv]; QueueManagers = @(); Error = "Niedostepny" })
                Write-Log "FAIL MQ: $srv"
            }
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
Write-Log "MQ: ${mqDuration}s"

# ===================================================================
$globalDuration = [math]::Round(((Get-Date) - $globalStart).TotalSeconds, 1)
Write-Log "=== KONIEC Collect-InfraDaily (${globalDuration}s) ==="
