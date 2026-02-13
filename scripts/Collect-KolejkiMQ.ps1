#Requires -Version 5.1
# =============================================================================
# Collect-KolejkiMQ.ps1
# Pobiera kolejki MQ z serwerow zdefiniowanych w mq_servers.json
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

$OutputFile = "$DataPath\infra_KolejkiMQ.json"
$LogPath = "$LogsPath\ServerHealthMonitor.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [MQ] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

Write-Log "=== START Collect-KolejkiMQ ==="
$startTime = Get-Date

# Wczytaj konfiguracje
$MQConfigPath = "$ConfigPath\mq_servers.json"
if (-not (Test-Path $MQConfigPath)) {
    Write-Log "BLAD: Brak pliku mq_servers.json"
    @{
        LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CollectionDuration = "0"
        TotalServers = 0
        Servers = @()
    } | ConvertTo-Json -Depth 10 | Out-File $OutputFile -Encoding UTF8
    exit 1
}

$mqConfig = Get-Content $MQConfigPath -Raw | ConvertFrom-Json

# Zbuduj mape serwer -> nazwa grupy oraz liste serwerow
$serverGroupMap = @{}
$targetServers = @()
$mqConfig.PSObject.Properties | ForEach-Object {
    $groupName = $_.Name
    foreach ($srv in $_.Value) {
        $serverGroupMap[$srv] = $groupName
        $targetServers += $srv
    }
}
$targetServers = $targetServers | Select-Object -Unique

if ($targetServers.Count -eq 0) {
    Write-Log "Brak serwerow MQ w konfiguracji"
    @{
        LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CollectionDuration = "0"
        TotalServers = 0
        Servers = @()
    } | ConvertTo-Json -Depth 10 | Out-File $OutputFile -Encoding UTF8
    exit 0
}

Write-Log "Serwery MQ: $($targetServers -join ', ')"

# Invoke-Command na wszystkie serwery naraz
$rawResults = Invoke-Command -ComputerName $targetServers -ErrorAction SilentlyContinue -ScriptBlock {
    $serverName = $env:COMPUTERNAME
    $queueManagers = @()

    try {
        $dspmqOutput = dspmq 2>$null
        if ($dspmqOutput) {
            foreach ($line in $dspmqOutput) {
                if ($line -match 'QMNAME\s*\(\s*(?<qm>.*?)\s*\).*?STATUS\s*\(\s*(?<stat>.*?)\s*\)') {
                    $qmName = $Matches['qm'].Trim()
                    $status = $Matches['stat'].Trim()

                    # Normalizuj status
                    $normalizedStatus = if ($status -match 'Running|Dzia') { "Running" } else { "Stopped" }

                    $port = ""
                    $queues = @()

                    if ($normalizedStatus -eq "Running") {
                        # Pobierz port
                        try {
                            $lsData = "DISPLAY LSSTATUS(*) PORT" | runmqsc $qmName 2>$null
                            foreach ($l in $lsData) {
                                if ($l -match 'PORT\s*\(\s*(?<p>\d+)\s*\)') {
                                    $port = $Matches['p']
                                    break
                                }
                            }
                        } catch {}

                        # Pobierz kolejki
                        try {
                            $qData = "DISPLAY QLOCAL(*)" | runmqsc $qmName 2>$null
                            foreach ($q in $qData) {
                                if ($q -match 'QUEUE\s*\(\s*(?<qn>.*?)\s*\)') {
                                    $qn = $Matches['qn'].Trim()
                                    if ($qn -notmatch '^SYSTEM\.|^AMQ\.') {
                                        $queues += @{ QueueName = $qn }
                                    }
                                }
                            }
                        } catch {}
                    }

                    $queueManagers += @{
                        QueueManager = $qmName
                        Status = $normalizedStatus
                        Port = $port
                        Queues = $queues
                    }
                }
            }
        }
    } catch {}

    @{
        ServerName = $serverName
        QueueManagers = $queueManagers
    }
}

# Przetwórz wyniki
$servers = [System.Collections.ArrayList]::new()

foreach ($r in $rawResults) {
    $srv = $r.PSComputerName
    [void]$servers.Add(@{
        ServerName = $r.ServerName
        Description = $serverGroupMap[$srv]
        Error = $null
        QueueManagers = @($r.QueueManagers)
    })
    $qmCount = ($r.QueueManagers | Measure-Object).Count
    $queueCount = ($r.QueueManagers | ForEach-Object { $_.Queues.Count } | Measure-Object -Sum).Sum
    Write-Log "OK: $($r.ServerName) ($qmCount QM, $queueCount kolejek)"
}

# Serwery ktore nie odpowiedzialy
$okServers = @($rawResults | ForEach-Object { $_.PSComputerName })
foreach ($srv in $targetServers) {
    if ($srv -notin $okServers) {
        [void]$servers.Add(@{
            ServerName = $srv
            Description = $serverGroupMap[$srv]
            Error = "Niedostepny"
            QueueManagers = @()
        })
        Write-Log "FAIL: $srv"
    }
}

$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

@{
    LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $duration.ToString()
    TotalServers = $servers.Count
    Servers = @($servers)
} | ConvertTo-Json -Depth 10 | Out-File $OutputFile -Encoding UTF8 -Force

Write-Log "=== KONIEC Collect-KolejkiMQ (${duration}s) ==="
