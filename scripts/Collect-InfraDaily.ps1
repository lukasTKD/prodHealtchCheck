#Requires -Version 5.1
# =============================================================================
# Collect-InfraDaily.ps1
# Zbiera dane infrastrukturalne: udziały sieciowe, instancje SQL, kolejki MQ
# Uruchamiany raz dziennie (np. o 6:00)
# Udziały sieciowe i instancje SQL czytane są z plików CSV
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

$LogPath = "$LogsPath\ServerHealthMonitor.log"
$LogMaxAgeHours = 48

# Funkcja do znalezienia pliku w kilku lokalizacjach
function Find-ConfigFile {
    param([string]$FileName, [string[]]$AlternativeNames = @())
    $names = @($FileName) + $AlternativeNames
    $basePaths = @(
        $ConfigPath,
        $BasePath,
        "D:\PROD_REPO_DATA\IIS\Cluster\data",
        "D:\PROD_REPO_DATA\IIS\Cluster"
    )
    foreach ($bp in $basePaths) {
        foreach ($name in $names) {
            $path = Join-Path $bp $name
            if (Test-Path $path) {
                return $path
            }
        }
    }
    return $null
}

$MQConfigPath = Find-ConfigFile "config_mq.json"
$FileShareCSVPath = Find-ConfigFile "fileshare.csv" @("fileShare.csv")
$SQLDetailsCSVPath = Find-ConfigFile "sql_db_details.csv"

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
    "$timestamp [INFRA] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

Write-Log "=== START zbierania danych infrastruktury ==="
$globalStart = Get-Date

# ===================================================================
# REGION 1: UDZIAŁY SIECIOWE (z pliku CSV)
# ===================================================================
Write-Log "--- Udzialy sieciowe (z CSV) ---"
$startShares = Get-Date
$shareResults = [System.Collections.ArrayList]::new()

if (Test-Path $FileShareCSVPath) {
    try {
        $csvData = Import-Csv -Path $FileShareCSVPath -Encoding UTF8

        # Grupuj po serwerze (kolumna ShareClusterRole lub ServerName)
        $serverColumn = if ($csvData[0].PSObject.Properties.Name -contains 'ShareClusterRole') { 'ShareClusterRole' }
                       elseif ($csvData[0].PSObject.Properties.Name -contains 'ServerName') { 'ServerName' }
                       else { $csvData[0].PSObject.Properties.Name[0] }

        $grouped = $csvData | Group-Object -Property $serverColumn

        foreach ($group in $grouped) {
            $serverName = $group.Name
            $shares = @($group.Group | ForEach-Object {
                @{
                    ShareName  = $_.ShareName
                    SharePath  = $_.SharePath
                    ShareState = if ($_.ShareState) { $_.ShareState } else { "Online" }
                }
            })

            [void]$shareResults.Add(@{
                ServerName = $serverName
                ShareCount = $shares.Count
                Shares     = $shares
                Error      = $null
            })
            Write-Log "OK Shares (CSV): $serverName ($($shares.Count) udzialow)"
        }
    }
    catch {
        Write-Log "BLAD: Nie mozna wczytac pliku CSV: $FileShareCSVPath - $($_.Exception.Message)"
    }
} else {
    Write-Log "INFO: Brak pliku CSV z udzialami: $FileShareCSVPath"
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
# REGION 2: INSTANCJE SQL (z pliku CSV)
# ===================================================================
Write-Log "--- Instancje SQL (z CSV) ---"
$startSQL = Get-Date
$sqlResults = [System.Collections.ArrayList]::new()

if (Test-Path $SQLDetailsCSVPath) {
    try {
        $csvData = Import-Csv -Path $SQLDetailsCSVPath -Encoding UTF8

        # Grupuj po serwerze SQL (kolumna sql_server lub ServerName)
        $serverColumn = if ($csvData[0].PSObject.Properties.Name -contains 'sql_server') { 'sql_server' }
                       elseif ($csvData[0].PSObject.Properties.Name -contains 'ServerName') { 'ServerName' }
                       else { $csvData[0].PSObject.Properties.Name[0] }

        $grouped = $csvData | Group-Object -Property $serverColumn

        foreach ($group in $grouped) {
            $serverName = $group.Name
            $firstRow = $group.Group[0]

            # Pobierz wersję SQL i edycję z pierwszego wiersza
            $sqlVersion = if ($firstRow.PSObject.Properties.Name -contains 'SQLServerVersion') { $firstRow.SQLServerVersion } else { "N/A" }
            $edition = if ($firstRow.PSObject.Properties.Name -contains 'Edition') { $firstRow.Edition } else { "N/A" }

            $databases = @($group.Group | ForEach-Object {
                @{
                    DatabaseName       = $_.DatabaseName
                    State              = if ($_.State) { $_.State } else { "ONLINE" }
                    CompatibilityLevel = if ($_.CompatibilityLevel) { [int]$_.CompatibilityLevel } else { 0 }
                }
            })

            [void]$sqlResults.Add(@{
                ServerName    = $serverName
                SQLVersion    = $sqlVersion
                Edition       = $edition
                DatabaseCount = $databases.Count
                Databases     = $databases
                Error         = $null
            })
            Write-Log "OK SQL (CSV): $serverName ($($databases.Count) baz)"
        }
    }
    catch {
        Write-Log "BLAD: Nie mozna wczytac pliku CSV: $SQLDetailsCSVPath - $($_.Exception.Message)"
    }
} else {
    Write-Log "INFO: Brak pliku CSV z instancjami SQL: $SQLDetailsCSVPath"
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
# REGION 3: KOLEJKI MQ (odpytywanie serwerów - bez zmian)
# ===================================================================
Write-Log "--- Kolejki MQ ---"
$startMQ = Get-Date
$mqResults = [System.Collections.ArrayList]::new()

if (Test-Path $MQConfigPath) {
    $mqConfig = Get-Content $MQConfigPath -Raw | ConvertFrom-Json
    $mqServers = @($mqConfig.servers)

    if ($mqServers.Count -gt 0) {
        # ScriptBlock do zdalnego odpytania MQ
        $mqScriptBlock = {
            $qmgrResults = @()
            $dspmqPath = "C:\Program Files\IBM\MQ\bin\dspmq.exe"

            if (Test-Path $dspmqPath) {
                $qmgrs = & $dspmqPath 2>$null
                foreach ($line in $qmgrs) {
                    if ($line -match 'QMNAME\((.*?)\)\s+STATUS\((.*?)\)') {
                        $qmgrName = $Matches[1]
                        $qmgrStatus = $Matches[2]

                        $queues = @()
                        $qmgrPort = ''
                        if ($qmgrStatus -eq 'Running') {
                            # Pobierz port listenera
                            try {
                                $lsnrCmd = "DISPLAY LISTENER(*) PORT`nEND"
                                $lsnrOutput = echo $lsnrCmd | & "C:\Program Files\IBM\MQ\bin\runmqsc.exe" $qmgrName 2>$null
                                foreach ($lline in $lsnrOutput) {
                                    if ($lline -match 'PORT\((\d+)\)') {
                                        $qmgrPort = $Matches[1]
                                        break
                                    }
                                }
                            } catch {}

                            try {
                                $cmd = "DISPLAY QLOCAL(*) CURDEPTH MAXDEPTH`nEND"
                                $queueOutput = echo $cmd | & "C:\Program Files\IBM\MQ\bin\runmqsc.exe" $qmgrName 2>$null

                                $currentQueue = $null
                                foreach ($qline in $queueOutput) {
                                    if ($qline -match 'QUEUE\((.*?)\)') {
                                        if ($currentQueue) { $queues += $currentQueue }
                                        $currentQueue = @{ QueueName = $Matches[1]; CurrentDepth = 0; MaxDepth = 0 }
                                    }
                                    if ($qline -match 'CURDEPTH\((\d+)\)' -and $currentQueue) {
                                        $currentQueue.CurrentDepth = [int]$Matches[1]
                                    }
                                    if ($qline -match 'MAXDEPTH\((\d+)\)' -and $currentQueue) {
                                        $currentQueue.MaxDepth = [int]$Matches[1]
                                    }
                                }
                                if ($currentQueue) { $queues += $currentQueue }
                                # Filtruj kolejki systemowe SYSTEM.*
                                $queues = @($queues | Where-Object { $_.QueueName -notmatch '^SYSTEM\.' })
                            } catch {}
                        }

                        $qmgrResults += @{
                            QueueManager = $qmgrName
                            Status       = $qmgrStatus
                            Port         = $qmgrPort
                            QueueCount   = $queues.Count
                            Queues       = $queues
                        }
                    }
                }
            }

            @{
                ServerName    = $env:COMPUTERNAME
                MQInstalled   = (Test-Path $dspmqPath)
                QueueManagers = $qmgrResults
            }
        }

        $mqServerNames = @($mqServers | ForEach-Object { $_.name })
        $mqRaw = Invoke-Command -ComputerName $mqServerNames -ScriptBlock $mqScriptBlock `
            -ErrorAction SilentlyContinue -ErrorVariable mqErrors

        foreach ($r in $mqRaw) {
            if ($r.ServerName) {
                $mqSrvConfig = $mqServers | Where-Object { $_.name -eq $r.PSComputerName } | Select-Object -First 1
                [void]$mqResults.Add(@{
                    ServerName    = $r.ServerName
                    Description   = if ($mqSrvConfig) { $mqSrvConfig.description } else { "" }
                    MQInstalled   = $r.MQInstalled
                    QueueManagers = @($r.QueueManagers)
                    Error         = $null
                })
                Write-Log "OK MQ: $($r.ServerName)"
            }
        }

        # Serwery niedostępne
        $okMQ = @($mqRaw | ForEach-Object { $_.PSComputerName })
        foreach ($srv in $mqServerNames) {
            if ($srv -notin $okMQ) {
                $mqSrvConfig = $mqServers | Where-Object { $_.name -eq $srv } | Select-Object -First 1
                [void]$mqResults.Add(@{
                    ServerName    = $srv
                    Description   = if ($mqSrvConfig) { $mqSrvConfig.description } else { "" }
                    MQInstalled   = $false
                    QueueManagers = @()
                    Error         = "Timeout/Niedostepny"
                })
                Write-Log "FAIL MQ: $srv"
            }
        }
    }
} else {
    Write-Log "INFO: Brak konfiguracji MQ ($MQConfigPath) - pomijam"
}

$mqDuration = [math]::Round(((Get-Date) - $startMQ).TotalSeconds, 1)
@{
    LastUpdate    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $mqDuration
    TotalServers  = $mqResults.Count
    Servers       = @($mqResults)
} | ConvertTo-Json -Depth 10 | Out-File "$DataPath\infra_KolejkiMQ.json" -Encoding UTF8 -Force
Write-Log "MQ zapisane (${mqDuration}s)"

# ===================================================================
# PODSUMOWANIE
# ===================================================================
$globalDuration = [math]::Round(((Get-Date) - $globalStart).TotalSeconds, 1)
Write-Log "=== KONIEC zbierania danych infrastruktury (${globalDuration}s) ==="
