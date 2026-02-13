#Requires -Version 5.1
# =============================================================================
# Collect-InfraDaily.ps1
# 3 sekcje: (1) FileShares, (2) SQL z CSV, (3) MQ (dspmq + kolejki)
# Bazuje na: Get-ClusterResources.ps1, sql_db_details.csv,
#            MQ_Qmanagers.ps1, MQ_kolejki_lista.ps1
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

$LogPath = "$LogsPath\ServerHealthMonitor.log"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts [INFRA] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

Write-Log "=== START Collect-InfraDaily ==="
Write-Log "ConfigPath=$ConfigPath, DataPath=$DataPath"
$globalStart = Get-Date

# --- Konfiguracje ---
$ClustersConfigPath = "$ConfigPath\clusters.json"
if (-not (Test-Path $ClustersConfigPath)) { $ClustersConfigPath = "D:\PROD_REPO_DATA\IIS\Cluster\clusters.json" }
Write-Log "Clusters config: $ClustersConfigPath (istnieje: $(Test-Path $ClustersConfigPath))"
$clustersConfig = $null
if (Test-Path $ClustersConfigPath) {
    try {
        $rawClusters = (Get-Content $ClustersConfigPath -Raw -ErrorAction Stop).Trim()
        if ($rawClusters -and $rawClusters.Length -gt 2) { $clustersConfig = $rawClusters | ConvertFrom-Json }
    } catch {
        Write-Log "BLAD parsowania clusters.json: $($_.Exception.Message)"
    }
}

$MQConfigPath = "$ConfigPath\mq_servers.json"
Write-Log "MQ config: $MQConfigPath (istnieje: $(Test-Path $MQConfigPath))"
$mqConfig = $null
if (Test-Path $MQConfigPath) {
    try {
        $rawMQ = (Get-Content $MQConfigPath -Raw -ErrorAction Stop).Trim()
        if ($rawMQ -and $rawMQ.Length -gt 2) { $mqConfig = $rawMQ | ConvertFrom-Json }
    } catch {
        Write-Log "BLAD parsowania mq_servers.json: $($_.Exception.Message)"
    }
}


# =====================================================================
# 1. UDZIALY SIECIOWE — Get-SmbShare -CimSession
#    Identyczny wzorzec jak Get-ClusterResources.ps1
# =====================================================================
Write-Log "--- Udzialy sieciowe ---"
$startShares = Get-Date
$shareResults = [System.Collections.ArrayList]::new()

if ($clustersConfig) {
    $fsServers = @($clustersConfig.clusters |
        Where-Object { $_.cluster_type -eq "FileShare" } |
        ForEach-Object { $_.servers } |
        ForEach-Object { $_ })

    foreach ($srv in $fsServers) {
        Write-Log "  FileShare: $srv"
        try {
            $shares = @(Get-SmbShare -CimSession $srv -Special $false -ErrorAction Stop |
                ForEach-Object {
                    [PSCustomObject]@{
                        ShareName  = $_.Name
                        SharePath  = $_.Path
                        ShareState = "Online"
                    }
                })

            [void]$shareResults.Add([PSCustomObject]@{
                ServerName = $srv
                ShareCount = $shares.Count
                Shares     = $shares
                Error      = $null
            })
            Write-Log "    OK: $($shares.Count) udzialow"
        } catch {
            [void]$shareResults.Add([PSCustomObject]@{
                ServerName = $srv
                ShareCount = 0
                Shares     = @()
                Error      = $_.Exception.Message
            })
            Write-Log "    FAIL: $($_.Exception.Message)"
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
Write-Log "Udzialy: ${sharesDuration}s ($($shareResults.Count) serwerow)"


# =====================================================================
# 2. INSTANCJE SQL — odczyt z istniejacego pliku CSV
#    Plik sql_db_details.csv jest generowany oddzielnie
# =====================================================================
Write-Log "--- Instancje SQL ---"
$startSQL = Get-Date
$sqlResults = [System.Collections.ArrayList]::new()

# Szukaj CSV w kilku mozliwych lokalizacjach
$sqlCsvPaths = @(
    "$DataPath\sql_db_details.csv",
    "$ConfigPath\sql_db_details.csv",
    "D:\PROD_REPO_DATA\IIS\Cluster\data\sql_db_details.csv"
)
$sqlCsvPath = $null
foreach ($p in $sqlCsvPaths) {
    if (Test-Path $p) { $sqlCsvPath = $p; break }
}

if ($sqlCsvPath) {
    Write-Log "  SQL CSV: $sqlCsvPath"
    $sqlCsv = Import-Csv $sqlCsvPath

    # Grupuj po sql_server
    $grouped = $sqlCsv | Group-Object -Property sql_server

    foreach ($grp in $grouped) {
        $serverName = $grp.Name
        $dbs = @($grp.Group | ForEach-Object {
            [PSCustomObject]@{
                DatabaseName       = $_.DatabaseName
                CompatibilityLevel = $_.CompatibilityLevel
                DataFileSizeMB     = [math]::Round([double]($_.DataFileSizeMB -replace ',', '.'), 2)
                LogFileSizeMB      = [math]::Round([double]($_.LogFileSizeMB -replace ',', '.'), 2)
                TotalSizeMB        = [math]::Round([double]($_.TotalSizeMB -replace ',', '.'), 2)
            }
        })

        $totalSize  = ($dbs | Measure-Object -Property TotalSizeMB -Sum).Sum
        $sqlVersion = if ($grp.Group[0].SQLServerVersion) { $grp.Group[0].SQLServerVersion } else { "N/A" }

        [void]$sqlResults.Add([PSCustomObject]@{
            ServerName    = $serverName
            SQLVersion    = $sqlVersion
            DatabaseCount = $dbs.Count
            TotalSizeMB   = [math]::Round($totalSize, 2)
            Databases     = $dbs
            Error         = $null
        })
        Write-Log "    OK: $serverName ($($dbs.Count) baz, $([math]::Round($totalSize, 0)) MB)"
    }
} else {
    Write-Log "  WARN: Brak pliku sql_db_details.csv w zadnej lokalizacji"
}

$sqlDuration = [math]::Round(((Get-Date) - $startSQL).TotalSeconds, 1)
@{
    LastUpdate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $sqlDuration
    TotalInstances     = $sqlResults.Count
    Instances          = @($sqlResults)
} | ConvertTo-Json -Depth 10 | Out-File "$DataPath\infra_InstancjeSQL.json" -Encoding UTF8 -Force
Write-Log "SQL: ${sqlDuration}s ($($sqlResults.Count) serwerow)"


# =====================================================================
# 3. KOLEJKI MQ — dspmq + runmqsc per serwer
#    Wzorzec z MQ_Qmanagers.ps1 + MQ_kolejki_lista.ps1
# =====================================================================
Write-Log "--- Kolejki MQ ---"
$startMQ = Get-Date
$mqResults = [System.Collections.ArrayList]::new()

if ($mqConfig) {
    foreach ($grpProp in $mqConfig.PSObject.Properties) {
        $groupName  = $grpProp.Name
        $grpServers = @($grpProp.Value)

        Write-Log "  MQ grupa $groupName : $($grpServers -join ', ')"

        foreach ($srv in $grpServers) {
            try {
                $mqRaw = Invoke-Command -ComputerName $srv -ErrorAction Stop -ScriptBlock {
                    $qmgrs = @()
                    $mqData = dspmq 2>$null
                    if ($mqData) {
                        foreach ($line in $mqData) {
                            if ($line -match 'QMNAME\s*\(\s*(?<name>.*?)\s*\)\s+STATUS\s*\(\s*(?<state>.*?)\s*\)') {
                                $qmName   = $Matches['name'].Trim()
                                $rawState = $Matches['state'].Trim()
                                $cleanState = $rawState -replace 'Dzia.+?c[ye]', 'Running'

                                $port   = ""
                                $queues = @()

                                if ($cleanState -match 'Running|Dzia') {
                                    # Port
                                    $lsData = "DISPLAY LSSTATUS(*) PORT" | runmqsc $qmName 2>$null
                                    if ($lsData) {
                                        foreach ($l in $lsData) {
                                            if ($l -match 'PORT\s*\(\s*(?<p>\d+)\s*\)') {
                                                $port = $Matches['p']; break
                                            }
                                        }
                                    }

                                    # Kolejki (bez SYSTEM.* i AMQ.*)
                                    $qData = "DISPLAY QLOCAL(*)" | runmqsc $qmName 2>$null
                                    if ($qData) {
                                        foreach ($q in $qData) {
                                            if ($q -match 'QUEUE\s*\(\s*(?<qn>.*?)\s*\)') {
                                                $qn = $Matches['qn'].Trim()
                                                if ($qn -notmatch '^SYSTEM\.|^AMQ\.') {
                                                    $queues += [PSCustomObject]@{ QueueName = $qn }
                                                }
                                            }
                                        }
                                    }
                                }

                                $qmgrs += [PSCustomObject]@{
                                    QueueManager = $qmName
                                    Status       = $cleanState
                                    Port         = $port
                                    QueueCount   = $queues.Count
                                    Queues       = $queues
                                }
                            }
                        }
                    }

                    [PSCustomObject]@{
                        ServerName    = $env:COMPUTERNAME
                        QueueManagers = $qmgrs
                    }
                }

                [void]$mqResults.Add([PSCustomObject]@{
                    ServerName    = $mqRaw.ServerName
                    Description   = $groupName
                    QueueManagers = @($mqRaw.QueueManagers)
                    Error         = $null
                })
                Write-Log "    OK: $($mqRaw.ServerName) ($(@($mqRaw.QueueManagers).Count) qm)"

            } catch {
                [void]$mqResults.Add([PSCustomObject]@{
                    ServerName    = $srv
                    Description   = $groupName
                    QueueManagers = @()
                    Error         = $_.Exception.Message
                })
                Write-Log "    FAIL: $srv - $($_.Exception.Message)"
            }
        }
    }
} else {
    Write-Log "  WARN: Brak pliku mq_servers.json"
}

$mqDuration = [math]::Round(((Get-Date) - $startMQ).TotalSeconds, 1)
@{
    LastUpdate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $mqDuration
    TotalServers       = $mqResults.Count
    Servers            = @($mqResults)
} | ConvertTo-Json -Depth 10 | Out-File "$DataPath\infra_KolejkiMQ.json" -Encoding UTF8 -Force
Write-Log "MQ: ${mqDuration}s ($($mqResults.Count) serwerow)"


# =====================================================================
$globalDuration = [math]::Round(((Get-Date) - $globalStart).TotalSeconds, 1)
Write-Log "=== KONIEC Collect-InfraDaily (${globalDuration}s) ==="
