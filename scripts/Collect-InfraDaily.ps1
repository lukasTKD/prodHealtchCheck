#Requires -Version 5.1
# =============================================================================
# Collect-InfraDaily.ps1
# Zbiera dane infrastrukturalne: udziały sieciowe, instancje SQL, kolejki MQ
# Uruchamiany raz dziennie (np. o 6:00)
# =============================================================================

$BasePath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
$ClustersConfigPath = "D:\PROD_REPO_DATA\IIS\Cluster\clusters.json"
$MQConfigPath = "$BasePath\config_mq.json"
$LogPath = "$BasePath\ServerHealthMonitor.log"
$LogMaxAgeHours = 48

$ErrorActionPreference = "Continue"

function Write-Log {
    param([string]$Message)
    if (Test-Path $LogPath) {
        $logFile = Get-Item $LogPath
        if ($logFile.LastWriteTime -lt (Get-Date).AddHours(-$LogMaxAgeHours)) {
            $archiveName = "$BasePath\ServerHealthMonitor_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            Move-Item $LogPath $archiveName -Force
        }
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [INFRA] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

# --- Wczytaj konfigurację klastrów ---
if (-not (Test-Path $ClustersConfigPath)) {
    Write-Log "BLAD: Brak pliku konfiguracji: $ClustersConfigPath"
    exit 1
}

$config = Get-Content $ClustersConfigPath -Raw | ConvertFrom-Json
$allClusters = @($config.clusters)

$sqlClusters = @($allClusters | Where-Object { $_.cluster_type -eq "SQL" })
$fileShareClusters = @($allClusters | Where-Object { $_.cluster_type -eq "FileShare" })

Write-Log "=== START zbierania danych infrastruktury ==="
$globalStart = Get-Date

# ===================================================================
# REGION 1: UDZIAŁY SIECIOWE
# ===================================================================
Write-Log "--- Udzialy sieciowe ---"
$startShares = Get-Date
$shareResults = [System.Collections.ArrayList]::new()

# Zbierz listę wszystkich file serwerów
$fileServers = [System.Collections.ArrayList]::new()
foreach ($fsCluster in $fileShareClusters) {
    foreach ($srv in $fsCluster.servers) {
        [void]$fileServers.Add($srv)
    }
}

if ($fileServers.Count -gt 0) {
    # Użyj Invoke-Command do równoległego zbierania udziałów
    $shareScriptBlock = {
        $shares = Get-SmbShare -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.ShareType -ne 'Special' }

        @{
            ServerName = $env:COMPUTERNAME
            Shares = @($shares | ForEach-Object {
                @{
                    ShareName  = $_.Name
                    SharePath  = $_.Path
                    ShareState = $_.ShareState.ToString()
                }
            })
        }
    }

    $shareRaw = Invoke-Command -ComputerName $fileServers -ScriptBlock $shareScriptBlock `
        -ErrorAction SilentlyContinue -ErrorVariable shareErrors

    foreach ($r in $shareRaw) {
        if ($r.ServerName) {
            [void]$shareResults.Add(@{
                ServerName = $r.ServerName
                ShareCount = $r.Shares.Count
                Shares     = @($r.Shares)
                Error      = $null
            })
            Write-Log "OK Shares: $($r.ServerName) ($($r.Shares.Count) udzialow)"
        }
    }

    # Serwery niedostępne
    $okServers = @($shareRaw | ForEach-Object { $_.PSComputerName })
    foreach ($srv in $fileServers) {
        if ($srv -notin $okServers) {
            $errMsg = ($shareErrors | Where-Object { $_.TargetObject -eq $srv } |
                       Select-Object -First 1).Exception.Message
            [void]$shareResults.Add(@{
                ServerName = $srv
                ShareCount = 0
                Shares     = @()
                Error      = if ($errMsg) { $errMsg } else { "Timeout/Niedostepny" }
            })
            Write-Log "FAIL Shares: $srv"
        }
    }
} else {
    Write-Log "INFO: Brak skonfigurowanych file serwerow"
}

$sharesDuration = [math]::Round(((Get-Date) - $startShares).TotalSeconds, 1)
@{
    LastUpdate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $sharesDuration
    TotalServers       = $shareResults.Count
    FileServers        = @($shareResults)
} | ConvertTo-Json -Depth 10 | Out-File "$BasePath\data\infra_UdzialySieciowe.json" -Encoding UTF8 -Force
Write-Log "Udzialy zapisane (${sharesDuration}s)"

# ===================================================================
# REGION 2: INSTANCJE SQL
# ===================================================================
Write-Log "--- Instancje SQL ---"
$startSQL = Get-Date
$sqlResults = [System.Collections.ArrayList]::new()

# Zbierz listę serwerów SQL
$sqlServers = [System.Collections.ArrayList]::new()
foreach ($sqlCluster in $sqlClusters) {
    foreach ($srv in $sqlCluster.servers) {
        [void]$sqlServers.Add($srv)
    }
}

if ($sqlServers.Count -gt 0) {
    $sqlQuery = @"
SELECT
    d.name AS DatabaseName,
    d.state_desc AS State,
    d.compatibility_level AS CompatibilityLevel,
    CONVERT(VARCHAR(20), SERVERPROPERTY('ProductVersion')) AS SQLServerVersion,
    CONVERT(VARCHAR(100), SERVERPROPERTY('Edition')) AS Edition
FROM sys.databases d
ORDER BY d.name
"@

    # OPTYMALIZACJA: Równoległe odpytywanie instancji SQL jeśli jest ich więcej niż 1
    if ($sqlServers.Count -eq 1) {
        # Pojedyncza instancja - wykonaj synchronicznie
        $sqlSrv = $sqlServers[0]
        try {
            $rawDbs = @(Invoke-Sqlcmd -ServerInstance $sqlSrv -Query $sqlQuery -QueryTimeout 30 -ErrorAction Stop)
            $databases = @($rawDbs | ForEach-Object {
                @{
                    DatabaseName       = $_.DatabaseName
                    State              = $_.State
                    CompatibilityLevel = [int]$_.CompatibilityLevel
                }
            })
            $sqlVersion = if ($rawDbs.Count -gt 0) { $rawDbs[0].SQLServerVersion } else { "N/A" }
            $edition    = if ($rawDbs.Count -gt 0) { $rawDbs[0].Edition } else { "N/A" }
            [void]$sqlResults.Add(@{
                ServerName    = $sqlSrv
                SQLVersion    = $sqlVersion
                Edition       = $edition
                DatabaseCount = $databases.Count
                Databases     = $databases
                Error         = $null
            })
            Write-Log "OK SQL: $sqlSrv ($($databases.Count) baz)"
        }
        catch {
            [void]$sqlResults.Add(@{
                ServerName    = $sqlSrv
                SQLVersion    = "N/A"
                Edition       = "N/A"
                DatabaseCount = 0
                Databases     = @()
                Error         = $_.Exception.Message
            })
            Write-Log "FAIL SQL: $sqlSrv - $($_.Exception.Message)"
        }
    } else {
        # Wiele instancji - użyj Start-Job dla równoległości
        $sqlJobs = @()
        $sqlScriptBlock = {
            param($sqlSrv, $sqlQuery)
            try {
                $rawDbs = @(Invoke-Sqlcmd -ServerInstance $sqlSrv -Query $sqlQuery -QueryTimeout 30 -ErrorAction Stop)
                $databases = @($rawDbs | ForEach-Object {
                    @{
                        DatabaseName       = $_.DatabaseName
                        State              = $_.State
                        CompatibilityLevel = [int]$_.CompatibilityLevel
                    }
                })
                $sqlVersion = if ($rawDbs.Count -gt 0) { $rawDbs[0].SQLServerVersion } else { "N/A" }
                $edition    = if ($rawDbs.Count -gt 0) { $rawDbs[0].Edition } else { "N/A" }
                @{
                    Success       = $true
                    ServerName    = $sqlSrv
                    SQLVersion    = $sqlVersion
                    Edition       = $edition
                    DatabaseCount = $databases.Count
                    Databases     = $databases
                    Error         = $null
                }
            }
            catch {
                @{
                    Success       = $false
                    ServerName    = $sqlSrv
                    SQLVersion    = "N/A"
                    Edition       = "N/A"
                    DatabaseCount = 0
                    Databases     = @()
                    Error         = $_.Exception.Message
                }
            }
        }

        foreach ($sqlSrv in $sqlServers) {
            $sqlJobs += Start-Job -ScriptBlock $sqlScriptBlock -ArgumentList $sqlSrv, $sqlQuery
        }

        # Czekaj na zakończenie wszystkich zadań
        $sqlJobs | Wait-Job | ForEach-Object {
            $result = Receive-Job $_
            Remove-Job $_
            
            if ($result.Success) {
                Write-Log "OK SQL: $($result.ServerName) ($($result.DatabaseCount) baz)"
            } else {
                Write-Log "FAIL SQL: $($result.ServerName) - $($result.Error)"
            }
            [void]$sqlResults.Add($result)
        }
    }
} else {
    Write-Log "INFO: Brak skonfigurowanych serwerow SQL"
}

$sqlDuration = [math]::Round(((Get-Date) - $startSQL).TotalSeconds, 1)
@{
    LastUpdate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $sqlDuration
    TotalInstances     = $sqlResults.Count
    Instances          = @($sqlResults)
} | ConvertTo-Json -Depth 10 | Out-File "$BasePath\data\infra_InstancjeSQL.json" -Encoding UTF8 -Force
Write-Log "SQL zapisane (${sqlDuration}s)"

# ===================================================================
# REGION 3: KOLEJKI MQ
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
} | ConvertTo-Json -Depth 10 | Out-File "$BasePath\data\infra_KolejkiMQ.json" -Encoding UTF8 -Force
Write-Log "MQ zapisane (${mqDuration}s)"

# ===================================================================
# PODSUMOWANIE
# ===================================================================
$globalDuration = [math]::Round(((Get-Date) - $globalStart).TotalSeconds, 1)
Write-Log "=== KONIEC zbierania danych infrastruktury (${globalDuration}s) ==="
