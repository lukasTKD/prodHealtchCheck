# Collect-InfraDaily.ps1
# Zbiera udzialy sieciowe + kolejki MQ -> fileShare.csv + mq_queue_list.csv
# SQL dane sa w sql_db_details.csv (bez zmian, api.aspx czyta bezposrednio)
# Wzor z: Get-ClusterResources.ps1, MQ_kolejki_lista.ps1
# ZERO JSON — tylko Import-Csv i Export-Csv

# --- SCIEZKI ---
$BasePath   = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
$DataPath   = "$BasePath\data"
$ConfigPath = "$BasePath\config"
$LogsPath   = "$BasePath\logs"

if (!(Test-Path $DataPath)) { New-Item -ItemType Directory -Path $DataPath -Force | Out-Null }
if (!(Test-Path $LogsPath)) { New-Item -ItemType Directory -Path $LogsPath -Force | Out-Null }

$LogFile = "$LogsPath\ServerHealthMonitor.log"
function Log($msg) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFRA] $msg" | Out-File $LogFile -Append -Encoding UTF8 }

Log "START Collect-InfraDaily"

# --- KONFIGURACJA Z CSV ---
$clustersCfg  = Import-Csv "$ConfigPath\clusters_config.csv"
$mqServersCfg = Import-Csv "$ConfigPath\mq_servers_config.csv"


# ==========================================
# 1. UDZIALY SIECIOWE
# Identycznie jak Get-ClusterResources.ps1
# ==========================================
Write-Host "=== Udzialy sieciowe ==="
Log "--- Udzialy sieciowe ---"

$shareResults = @()
$fsServers = @($clustersCfg | Where-Object { $_.ClusterType -eq "FileShare" } | ForEach-Object { $_.ServerName })
Write-Host "Serwery FileShare: $($fsServers -join ', ')"

foreach ($srv in $fsServers) {
    Write-Host "  $srv ..."
    Log "  FileShare: $srv"
    try {
        $shares = Get-SmbShare -CimSession $srv -Special $false -ErrorAction Stop
        foreach ($s in $shares) {
            $shareResults += [PSCustomObject]@{
                ServerName = $srv
                ShareName  = $s.Name
                SharePath  = $s.Path
                ShareState = "Online"
            }
        }
        Write-Host "    OK: $(@($shares).Count) udzialow" -ForegroundColor Green
        Log "    OK: $(@($shares).Count) udzialow"
    } catch {
        $shareResults += [PSCustomObject]@{
            ServerName = $srv
            ShareName  = "ERROR"
            SharePath  = $_.Exception.Message
            ShareState = "Error"
        }
        Write-Host "    BLAD: $($_.Exception.Message)" -ForegroundColor Red
        Log "    BLAD: $($_.Exception.Message)"
    }
}

$shareCsv = "$DataPath\fileShare.csv"
if (Test-Path $shareCsv) { Remove-Item $shareCsv }
if ($shareResults.Count -gt 0) {
    $shareResults | Export-Csv -Path $shareCsv -NoTypeInformation -Encoding UTF8
}
Write-Host "Zapisano: fileShare.csv ($($shareResults.Count) wierszy)"
Log "FileShares: $($shareResults.Count) wierszy"


# ==========================================
# 2. SQL — juz istnieje w sql_db_details.csv
# api.aspx czyta ten plik bezposrednio, nic tu nie robimy
# ==========================================
Write-Host "`n=== SQL ==="
$sqlPaths = @("$DataPath\sql_db_details.csv", "D:\PROD_REPO_DATA\IIS\Cluster\data\sql_db_details.csv")
$sqlFound = $false
foreach ($p in $sqlPaths) {
    if (Test-Path $p) { Write-Host "  SQL CSV istnieje: $p ($(((Get-Item $p).Length / 1KB).ToString('0.0')) KB)"; $sqlFound = $true; break }
}
if (!$sqlFound) { Write-Host "  BRAK sql_db_details.csv" -ForegroundColor Yellow }
Log "SQL: $(if ($sqlFound) { 'OK' } else { 'BRAK' })"


# ==========================================
# 3. KOLEJKI MQ
# Identycznie jak MQ_kolejki_lista.ps1
# ==========================================
Write-Host "`n=== Kolejki MQ ==="
Log "--- Kolejki MQ ---"

$mqResults = @()
$allMQServers = @($mqServersCfg | ForEach-Object { $_.ServerName })
Write-Host "Serwery MQ: $($allMQServers -join ', ')"

# Mapowanie serwer -> grupa
$srvToGroup = @{}
foreach ($entry in $mqServersCfg) { $srvToGroup[$entry.ServerName] = $entry.GroupName }

# Jedno wywolanie na wszystkie serwery MQ
$mqRaw = Invoke-Command -ComputerName $allMQServers -ErrorAction SilentlyContinue -ErrorVariable mqErrs -ScriptBlock {
    $ServerName = $env:COMPUTERNAME

    try {
        $dspmqOutput = dspmq 2>$null
        if ($dspmqOutput) {
            foreach ($line in $dspmqOutput) {
                if ($line -match 'QMNAME\s*\(\s*(?<qm>.*?)\s*\).*?STATUS\s*\(\s*(?<stat>.*?)\s*\)') {
                    $qmName = $Matches['qm'].Trim()
                    $status = $Matches['stat'].Trim() -replace 'Dzia.+?c[ye]', 'Running'

                    $Port = ""
                    $queues = @()

                    if ($status -match 'Running|Dzia') {
                        # Port
                        $ls = "DISPLAY LSSTATUS(*) PORT" | runmqsc $qmName 2>$null
                        if ($ls) { foreach ($l in $ls) { if ($l -match 'PORT\s*\(\s*(?<p>\d+)\s*\)') { $Port = $Matches['p']; break } } }

                        # Kolejki
                        $qd = "DISPLAY QLOCAL(*)" | runmqsc $qmName 2>$null
                        if ($qd) {
                            foreach ($q in $qd) {
                                if ($q -match 'QUEUE\s*\(\s*(?<qn>.*?)\s*\)') {
                                    $qn = $Matches['qn'].Trim()
                                    if ($qn -notmatch '^SYSTEM\.|^AMQ\.') {
                                        $queues += $qn
                                    }
                                }
                            }
                        }
                    }

                    # Wiersz na kazda kolejke
                    foreach ($qn in $queues) {
                        [PSCustomObject]@{
                            QManager   = $qmName
                            Status     = $status
                            Port       = $Port
                            QueueName  = $qn
                            ServerName = $ServerName
                        }
                    }
                    # Jesli brak kolejek, dodaj sam QManager
                    if ($queues.Count -eq 0) {
                        [PSCustomObject]@{
                            QManager   = $qmName
                            Status     = $status
                            Port       = $Port
                            QueueName  = ""
                            ServerName = $ServerName
                        }
                    }
                }
            }
        }
    } catch {
        [PSCustomObject]@{
            QManager   = "ERROR"
            Status     = "Blad"
            Port       = ""
            QueueName  = $_.Exception.Message
            ServerName = $ServerName
        }
    }
}

foreach ($r in $mqRaw) {
    $mqResults += [PSCustomObject]@{
        QManager   = $r.QManager
        Status     = $r.Status
        Port       = $r.Port
        QueueName  = $r.QueueName
        ServerName = $r.ServerName
        GroupName  = $srvToGroup[$r.PSComputerName]
    }
}

foreach ($err in $mqErrs) {
    Write-Host "  BLAD MQ: $($err.TargetObject) - $($err.Exception.Message)" -ForegroundColor Red
    Log "  BLAD MQ: $($err.TargetObject) - $($err.Exception.Message)"
}

$mqCsv = "$DataPath\mq_queue_list.csv"
if (Test-Path $mqCsv) { Remove-Item $mqCsv }
if ($mqResults.Count -gt 0) {
    $mqResults | Export-Csv -Path $mqCsv -NoTypeInformation -Encoding UTF8
}
Write-Host "Zapisano: mq_queue_list.csv ($($mqResults.Count) wierszy)"
Log "MQ: $($mqResults.Count) wierszy"


Write-Host "`n=== GOTOWE ===" -ForegroundColor Green
Log "KONIEC Collect-InfraDaily"
