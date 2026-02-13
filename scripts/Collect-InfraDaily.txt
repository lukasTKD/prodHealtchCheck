# Collect-InfraDaily.ps1
# Prosty skrypt — FileShares, SQL z CSV, MQ kolejki
# Wzor: Get-ClusterResources.ps1, MQ_Qmanagers.ps1, MQ_kolejki_lista.ps1

# --- SCIEZKI ---
$ScriptDir  = Split-Path $PSScriptRoot -Parent
$appConfig  = Get-Content "$ScriptDir\app-config.json" -Raw | ConvertFrom-Json
$DataPath   = $appConfig.paths.dataPath
$ConfigPath = $appConfig.paths.configPath
$LogsPath   = $appConfig.paths.logsPath

if (!(Test-Path $DataPath)) { New-Item -ItemType Directory -Path $DataPath -Force | Out-Null }
if (!(Test-Path $LogsPath)) { New-Item -ItemType Directory -Path $LogsPath -Force | Out-Null }

$LogFile = "$LogsPath\ServerHealthMonitor.log"
function Log($msg) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFRA] $msg" | Out-File $LogFile -Append -Encoding UTF8 }

Log "=== START Collect-InfraDaily ==="

$clustersJson = Get-Content "$ConfigPath\clusters.json" -Raw | ConvertFrom-Json
$mqJson       = $null
$mqFile       = "$ConfigPath\mq_servers.json"
if (Test-Path $mqFile) { $mqJson = Get-Content $mqFile -Raw | ConvertFrom-Json }


# ==========================================
# 1. UDZIALY SIECIOWE
# Wzor z Get-ClusterResources.ps1: Get-SmbShare -CimSession
# ==========================================
Log "--- Udzialy sieciowe ---"
$shareResults = @()

$fsServers = @($clustersJson.clusters | Where-Object { $_.cluster_type -eq "FileShare" } | ForEach-Object { $_.servers } | ForEach-Object { $_ })

foreach ($srv in $fsServers) {
    Log "  FileShare: $srv"
    try {
        $shares = @(Get-SmbShare -CimSession $srv -Special $false -ErrorAction Stop | ForEach-Object {
            [PSCustomObject]@{ ShareName = $_.Name; SharePath = $_.Path; ShareState = "Online" }
        })
        $shareResults += [PSCustomObject]@{ ServerName = $srv; ShareCount = $shares.Count; Shares = $shares; Error = $null }
        Log "    OK: $($shares.Count) udzialow"
    } catch {
        $shareResults += [PSCustomObject]@{ ServerName = $srv; ShareCount = 0; Shares = @(); Error = $_.Exception.Message }
        Log "    FAIL: $($_.Exception.Message)"
    }
}

@{
    LastUpdate   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    TotalServers = $shareResults.Count
    FileServers  = $shareResults
} | ConvertTo-Json -Depth 10 | Out-File "$DataPath\infra_UdzialySieciowe.json" -Encoding UTF8 -Force

Log "Udzialy: $($shareResults.Count) serwerow"


# ==========================================
# 2. INSTANCJE SQL — z pliku CSV
# ==========================================
Log "--- Instancje SQL ---"
$sqlResults = @()

# Szukaj CSV
$sqlCsv = $null
foreach ($p in @("$DataPath\sql_db_details.csv", "$ConfigPath\sql_db_details.csv", "D:\PROD_REPO_DATA\IIS\Cluster\data\sql_db_details.csv")) {
    if (Test-Path $p) { $sqlCsv = Import-Csv $p; Log "  SQL CSV: $p"; break }
}

if ($sqlCsv) {
    $grouped = $sqlCsv | Group-Object -Property sql_server
    foreach ($grp in $grouped) {
        $dbs = @($grp.Group | ForEach-Object {
            [PSCustomObject]@{
                DatabaseName       = $_.DatabaseName
                CompatibilityLevel = $_.CompatibilityLevel
                DataFileSizeMB     = [math]::Round([double]($_.DataFileSizeMB -replace ',','.'), 2)
                LogFileSizeMB      = [math]::Round([double]($_.LogFileSizeMB -replace ',','.'), 2)
                TotalSizeMB        = [math]::Round([double]($_.TotalSizeMB -replace ',','.'), 2)
            }
        })
        $totalMB = ($dbs | Measure-Object -Property TotalSizeMB -Sum).Sum
        $sqlResults += [PSCustomObject]@{
            ServerName    = $grp.Name
            SQLVersion    = $(if ($grp.Group[0].SQLServerVersion) { $grp.Group[0].SQLServerVersion } else { "N/A" })
            DatabaseCount = $dbs.Count
            TotalSizeMB   = [math]::Round($totalMB, 2)
            Databases     = $dbs
            Error         = $null
        }
        Log "    $($grp.Name): $($dbs.Count) baz"
    }
} else {
    Log "  WARN: Brak sql_db_details.csv"
}

@{
    LastUpdate     = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    TotalInstances = $sqlResults.Count
    Instances      = $sqlResults
} | ConvertTo-Json -Depth 10 | Out-File "$DataPath\infra_InstancjeSQL.json" -Encoding UTF8 -Force

Log "SQL: $($sqlResults.Count) serwerow"


# ==========================================
# 3. KOLEJKI MQ
# Wzor z MQ_Qmanagers.ps1 + MQ_kolejki_lista.ps1
# ==========================================
Log "--- Kolejki MQ ---"
$mqResults = @()

if ($mqJson) {
    # Zbierz WSZYSTKIE serwery MQ + mapowanie serwer -> grupa
    $allMQServers = @()
    $mqGroupMap   = @{}
    foreach ($grp in $mqJson.PSObject.Properties) {
        foreach ($srv in $grp.Value) {
            $allMQServers += $srv
            $mqGroupMap[$srv] = $grp.Name
        }
    }
    Log "  MQ serwery: $($allMQServers -join ', ')"

    # JEDNO wywolanie na WSZYSTKIE serwery MQ — rownolegle
    $mqRawAll = Invoke-Command -ComputerName $allMQServers -ErrorAction SilentlyContinue -ErrorVariable mqErrs -ScriptBlock {
        $qmgrs = @()
        $mqData = dspmq 2>$null
        if ($mqData) {
            foreach ($line in $mqData) {
                if ($line -match 'QMNAME\s*\(\s*(?<name>.*?)\s*\)\s+STATUS\s*\(\s*(?<state>.*?)\s*\)') {
                    $qmName = $Matches['name'].Trim()
                    $state  = $Matches['state'].Trim() -replace 'Dzia.+?c[ye]', 'Running'
                    $port   = ""
                    $queues = @()

                    if ($state -match 'Running|Dzia') {
                        $ls = "DISPLAY LSSTATUS(*) PORT" | runmqsc $qmName 2>$null
                        if ($ls) { foreach ($l in $ls) { if ($l -match 'PORT\s*\(\s*(?<p>\d+)\s*\)') { $port = $Matches['p']; break } } }

                        $qd = "DISPLAY QLOCAL(*)" | runmqsc $qmName 2>$null
                        if ($qd) { foreach ($q in $qd) { if ($q -match 'QUEUE\s*\(\s*(?<qn>.*?)\s*\)') { $qn = $Matches['qn'].Trim(); if ($qn -notmatch '^SYSTEM\.|^AMQ\.') { $queues += [PSCustomObject]@{ QueueName = $qn } } } } }
                    }

                    $qmgrs += [PSCustomObject]@{ QueueManager = $qmName; Status = $state; Port = $port; QueueCount = $queues.Count; Queues = $queues }
                }
            }
        }
        [PSCustomObject]@{ ServerName = $env:COMPUTERNAME; QueueManagers = $qmgrs }
    }

    # Przetwarzanie wynikow
    foreach ($r in $mqRawAll) {
        $grpName = $mqGroupMap[$r.PSComputerName]
        $mqResults += [PSCustomObject]@{ ServerName = $r.ServerName; Description = $grpName; QueueManagers = @($r.QueueManagers); Error = $null }
        Log "    OK: $($r.ServerName) ($grpName)"
    }
    # Serwery ktore nie odpowiedzialy
    $okMQ = @($mqRawAll | ForEach-Object { $_.PSComputerName })
    foreach ($srv in $allMQServers) {
        if ($srv -notin $okMQ) {
            $mqResults += [PSCustomObject]@{ ServerName = $srv; Description = $mqGroupMap[$srv]; QueueManagers = @(); Error = "Niedostepny" }
            Log "    FAIL: $srv"
        }
    }
} else {
    Log "  WARN: Brak mq_servers.json"
}

@{
    LastUpdate   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    TotalServers = $mqResults.Count
    Servers      = $mqResults
} | ConvertTo-Json -Depth 10 | Out-File "$DataPath\infra_KolejkiMQ.json" -Encoding UTF8 -Force

Log "MQ: $($mqResults.Count) serwerow"
Log "=== KONIEC Collect-InfraDaily ==="
