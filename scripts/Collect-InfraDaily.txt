#Requires -Version 5.1
# =============================================================================
# Collect-InfraDaily.ps1
# Zbiera dane infrastrukturalne: udzialy sieciowe, instancje SQL, kolejki MQ
# Uruchamiany raz dziennie (np. o 6:00)
# Udzialy sieciowe i instancje SQL czytane sa z plikow CSV
# MQ - odpytywanie zdalne przez Invoke-Command (logika z old_working_ps)
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

# Szukaj plikow konfiguracyjnych (obsluga obu nazw dla MQ)
$MQConfigPath = Find-ConfigFile "mq_servers.json" @("config_mq.json")
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
# REGION 1: UDZIALY SIECIOWE (z pliku CSV)
# ===================================================================
Write-Log "--- Udzialy sieciowe (z CSV) ---"
$startShares = Get-Date
$shareResults = [System.Collections.ArrayList]::new()

if ($FileShareCSVPath -and (Test-Path $FileShareCSVPath)) {
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
                # ShareState: 1 = Online, inne = Offline
                $stateRaw = $_.ShareState
                $stateText = if ($stateRaw -eq '1' -or $stateRaw -eq 'Online' -or $stateRaw -eq 'True') { 'Online' } else { 'Offline' }
                @{
                    ShareName  = $_.ShareName
                    SharePath  = $_.SharePath
                    ShareState = $stateText
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

if ($SQLDetailsCSVPath -and (Test-Path $SQLDetailsCSVPath)) {
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

            # Pobierz wersje SQL i edycje z pierwszego wiersza
            $sqlVersion = if ($firstRow.PSObject.Properties.Name -contains 'SQLServerVersion') { $firstRow.SQLServerVersion } else { "N/A" }
            $edition = if ($firstRow.PSObject.Properties.Name -contains 'Edition') { $firstRow.Edition } else { "N/A" }

            $databases = @($group.Group | ForEach-Object {
                @{
                    DatabaseName       = $_.DatabaseName
                    State              = $(if ($_.State) { $_.State } else { "ONLINE" })
                    CompatibilityLevel = $(if ($_.CompatibilityLevel) { [int]$_.CompatibilityLevel } else { 0 })
                    DataFileLocation   = $(if ($_.DataFileLocation) { $_.DataFileLocation } else { '' })
                    DataFileSizeMB     = $(if ($_.DataFileSizeMB) { [math]::Round([double]$_.DataFileSizeMB, 0) } else { 0 })
                    LogFileLocation    = $(if ($_.LogFileLocation) { $_.LogFileLocation } else { '' })
                    LogFileSizeMB      = $(if ($_.LogFileSizeMB) { [math]::Round([double]$_.LogFileSizeMB, 0) } else { 0 })
                    TotalSizeMB        = $(if ($_.TotalSizeMB) { [math]::Round([double]$_.TotalSizeMB, 0) } else { 0 })
                }
            })

            # Oblicz laczny rozmiar wszystkich baz na tym serwerze
            $totalServerSizeMB = ($databases | Measure-Object -Property TotalSizeMB -Sum).Sum

            [void]$sqlResults.Add(@{
                ServerName      = $serverName
                SQLVersion      = $sqlVersion
                Edition         = $edition
                DatabaseCount   = $databases.Count
                TotalSizeMB     = [math]::Round($totalServerSizeMB, 0)
                Databases       = $databases
                Error           = $null
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
# REGION 3: KOLEJKI MQ (odpytywanie zdalne - logika z old_working_ps)
# ===================================================================
Write-Log "--- Kolejki MQ ---"
$startMQ = Get-Date
$mqResults = [System.Collections.ArrayList]::new()

if ($MQConfigPath -and (Test-Path $MQConfigPath)) {
    Write-Log "Uzywam konfiguracji MQ: $MQConfigPath"

    try {
        $mqConfig = Get-Content $MQConfigPath -Raw | ConvertFrom-Json

        # Obsluga nowego formatu mq_servers.json: { "Klaster1": ["srv1", "srv2"], "Klaster2": ["srv3", "srv4"] }
        # oraz starego formatu config_mq.json: { "servers": [{ "name": "srv1", "description": "..." }] }

        $mqServerList = @()

        if ($mqConfig.servers) {
            # Stary format: { "servers": [{ "name": "srv1", "description": "desc" }] }
            foreach ($srv in $mqConfig.servers) {
                $mqServerList += @{
                    ClusterName = ""
                    ServerName  = $srv.name
                    Description = $srv.description
                }
            }
        } else {
            # Nowy format: { "Klaster1": ["srv1", "srv2"], ... }
            foreach ($prop in $mqConfig.PSObject.Properties) {
                $clusterName = $prop.Name
                $servers = @($prop.Value)
                foreach ($srv in $servers) {
                    $mqServerList += @{
                        ClusterName = $clusterName
                        ServerName  = $srv
                        Description = $clusterName
                    }
                }
            }
        }

        Write-Log "Znaleziono $($mqServerList.Count) serwerow MQ do odpytania"

        if ($mqServerList.Count -gt 0) {
            # Zbierz unikalne nazwy serwerow
            $uniqueServerNames = @($mqServerList | ForEach-Object { $_.ServerName } | Select-Object -Unique)

            # ScriptBlock do zdalnego odpytania MQ (logika z old_working_ps/MQ_Qmanagers.ps1)
            $mqScriptBlock = {
                $qmgrResults = @()
                $NodeName = $env:COMPUTERNAME

                try {
                    # Uruchom dspmq i sparsuj wyniki
                    $mqData = dspmq 2>$null

                    if ($mqData) {
                        foreach ($line in $mqData) {
                            # Regex z obsluga polskich znakow
                            if ($line -match 'QMNAME\s*\(\s*(?<name>.*?)\s*\)\s+STATUS\s*\(\s*(?<state>.*?)\s*\)') {
                                $qmName = $Matches['name'].Trim()
                                $rawState = $Matches['state'].Trim()

                                # Naprawa polskich znakow
                                $cleanState = $rawState -replace 'Dzia.+?c[ye]', 'Running'
                                if ($cleanState -notmatch 'Running|Ended') {
                                    $cleanState = $rawState
                                }

                                $Port = ""
                                $queues = @()

                                # Jezeli manager dziala - pobierz port i kolejki
                                if ($cleanState -match 'Running|Dzia') {
                                    # Pobierz port listenera
                                    try {
                                        $listenerData = "DISPLAY LSSTATUS(*) PORT" | runmqsc $qmName 2>$null
                                        if ($listenerData) {
                                            foreach ($lLine in $listenerData) {
                                                if ($lLine -match 'PORT\s*\(\s*(?<p>\d+)\s*\)') {
                                                    $Port = $Matches['p']
                                                    break
                                                }
                                            }
                                        }
                                    } catch {}

                                    # Pobierz kolejki lokalne (bez systemowych)
                                    try {
                                        $queueOutput = "DISPLAY QLOCAL(*)" | runmqsc $qmName 2>$null
                                        if ($queueOutput) {
                                            foreach ($qLine in $queueOutput) {
                                                if ($qLine -match 'QUEUE\s*\(\s*(?<qname>.*?)\s*\)') {
                                                    $qName = $Matches['qname'].Trim()
                                                    # Filtr: pomijamy kolejki systemowe IBM
                                                    if ($qName -notmatch '^SYSTEM\.|^AMQ\.') {
                                                        $queues += @{
                                                            QueueName    = $qName
                                                            CurrentDepth = 0
                                                            MaxDepth     = 0
                                                        }
                                                    }
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
                } catch {
                    # Blad dspmq
                }

                @{
                    ServerName    = $NodeName
                    MQInstalled   = ($qmgrResults.Count -gt 0)
                    QueueManagers = $qmgrResults
                }
            }

            # Odpytaj wszystkie serwery MQ rownolegle
            Write-Log "Odpytuje serwery MQ: $($uniqueServerNames -join ', ')"

            $mqRaw = Invoke-Command -ComputerName $uniqueServerNames -ScriptBlock $mqScriptBlock `
                -ErrorAction SilentlyContinue -ErrorVariable mqErrors

            # Przetworz wyniki
            foreach ($r in $mqRaw) {
                if ($r.ServerName) {
                    # Znajdz opis klastra dla tego serwera
                    $srvConfig = $mqServerList | Where-Object { $_.ServerName -eq $r.PSComputerName } | Select-Object -First 1

                    [void]$mqResults.Add(@{
                        ServerName    = $r.ServerName
                        Description   = if ($srvConfig) { $srvConfig.Description } else { "" }
                        MQInstalled   = $r.MQInstalled
                        QueueManagers = @($r.QueueManagers)
                        Error         = $null
                    })
                    Write-Log "OK MQ: $($r.ServerName) - $($r.QueueManagers.Count) managerow"
                }
            }

            # Serwery niedostepne
            $okMQ = @($mqRaw | ForEach-Object { $_.PSComputerName })
            foreach ($srv in $uniqueServerNames) {
                if ($srv -notin $okMQ) {
                    $srvConfig = $mqServerList | Where-Object { $_.ServerName -eq $srv } | Select-Object -First 1
                    [void]$mqResults.Add(@{
                        ServerName    = $srv
                        Description   = if ($srvConfig) { $srvConfig.Description } else { "" }
                        MQInstalled   = $false
                        QueueManagers = @()
                        Error         = "Timeout/Niedostepny"
                    })
                    Write-Log "FAIL MQ: $srv"
                }
            }
        }
    }
    catch {
        Write-Log "BLAD: Nie mozna sparsowac pliku konfiguracji MQ: $MQConfigPath - $($_.Exception.Message)"
    }
} else {
    Write-Log "INFO: Brak konfiguracji MQ - pomijam"
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
