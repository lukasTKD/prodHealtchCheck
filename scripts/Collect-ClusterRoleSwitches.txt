# Collect-ClusterRoleSwitches.ps1
# Zbiera eventy przelaczen z klastrow SQL i FileShare -> role_switches.csv
# ZERO JSON — tylko Import-Csv i Export-Csv

# --- SCIEZKI Z app-config.json ---
$ScriptDir  = Split-Path $PSScriptRoot -Parent
$appConfig  = (Get-Content "$ScriptDir\app-config.json" -Raw).Trim() | ConvertFrom-Json
$DataPath   = $appConfig.paths.dataPath
$ConfigPath = $appConfig.paths.configPath
$LogsPath   = $appConfig.paths.logsPath
$DaysBack   = 30

if (!(Test-Path $DataPath)) { New-Item -ItemType Directory -Path $DataPath -Force | Out-Null }
if (!(Test-Path $LogsPath)) { New-Item -ItemType Directory -Path $LogsPath -Force | Out-Null }

$LogFile = "$LogsPath\ServerHealthMonitor.log"
function Log($msg) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [ROLE-SWITCH] $msg" | Out-File $LogFile -Append -Encoding UTF8 }

Log "START Collect-ClusterRoleSwitches"

# --- KONFIGURACJA Z CSV (plik wskazany w app-config.json) ---
$clustersCfg = Import-Csv "$ConfigPath\$($appConfig.scripts.'Collect-ClusterRoleSwitches'.sourceFile)"

# Tylko SQL i FileShare — MQ nie maja FailoverClustering
$sqlFsServers = @($clustersCfg | Where-Object { $_.ClusterType -ne "MQ" })
Write-Host "Klastry SQL/FS: $($sqlFsServers.Count) serwerow"
Log "Klastry SQL/FS: $($sqlFsServers.Count) serwerow"

if ($sqlFsServers.Count -eq 0) {
    Write-Host "Brak klastrow" -ForegroundColor Yellow
    Log "Brak klastrow"
    # Pusty CSV z naglowkiem
    [PSCustomObject]@{
        TimeCreated = ""; EventId = ""; EventType = ""; ClusterName = ""
        ClusterType = ""; RoleName = ""; SourceNode = ""; TargetNode = ""; ReportedBy = ""
    } | Export-Csv -Path "$DataPath\role_switches.csv" -NoTypeInformation -Encoding UTF8
    # Nadpisz pustym (tylko naglowek)
    "TimeCreated,EventId,EventType,ClusterName,ClusterType,RoleName,SourceNode,TargetNode,ReportedBy" | Out-File "$DataPath\role_switches.csv" -Encoding UTF8
    exit 0
}

# KROK 1: Znajdz klastry i ich wezly
$done = @{}
$nodeMap = @()

foreach ($entry in $sqlFsServers) {
    $srv  = $entry.ServerName
    $type = $entry.ClusterType
    Write-Host "  $type : $srv"

    try {
        $info = Invoke-Command -ComputerName $srv -ErrorAction Stop -ScriptBlock {
            [PSCustomObject]@{
                ClusterName = (Get-Cluster).Name
                Nodes       = @(Get-ClusterNode | Select-Object -ExpandProperty Name)
            }
        }

        if ($done[$info.ClusterName]) { Write-Host "    Pomijam duplikat"; continue }
        $done[$info.ClusterName] = $true

        foreach ($node in $info.Nodes) {
            $nodeMap += [PSCustomObject]@{ ClusterName = $info.ClusterName; ClusterType = $type; NodeName = $node }
        }
        Write-Host "    OK: $($info.ClusterName) ($($info.Nodes.Count) wezlow)" -ForegroundColor Green
        Log "  $($info.ClusterName) ($type): $($info.Nodes.Count) wezlow"
    } catch {
        Write-Host "    BLAD: $($_.Exception.Message)" -ForegroundColor Red
        Log "  BLAD $srv : $($_.Exception.Message)"
    }
}

$uniqueNodes = @($nodeMap | ForEach-Object { $_.NodeName } | Sort-Object -Unique)
Write-Host "`nWezly ($($uniqueNodes.Count)): $($uniqueNodes -join ', ')"
Log "Odpytuje $($uniqueNodes.Count) wezlow"

# KROK 2: Pobierz eventy przelaczen
$eventIDs  = @(1069, 1070, 1071, 1201, 1202, 1205, 1564, 1566)
$startDate = (Get-Date).AddDays(-$DaysBack)
$switches  = @()

if ($uniqueNodes.Count -gt 0) {
    $raw = Invoke-Command -ComputerName $uniqueNodes -ErrorAction SilentlyContinue -ErrorVariable evtErrors -ScriptBlock {
        param($startDate, $eventIDs)
        try {
            Get-WinEvent -FilterHashtable @{
                LogName   = 'Microsoft-Windows-FailoverClustering/Operational'
                StartTime = $startDate
                Id        = $eventIDs
            } -ErrorAction SilentlyContinue | ForEach-Object {
                $msg = $_.Message
                $role = ""; $target = ""; $source = ""
                if ($msg -match "Cluster group '([^']+)'")       { $role   = $Matches[1] }
                elseif ($msg -match "Cluster resource '([^']+)'") { $role = $Matches[1] }
                if ($msg -match "node '([^']+)'")        { $target = $Matches[1] }
                if ($msg -match "from node '([^']+)'")   { $source = $Matches[1] }

                [PSCustomObject]@{
                    TimeCreated = $_.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                    EventId     = $_.Id
                    EventType   = switch ($_.Id) {
                        1069 {"ResourceOnline"} 1070 {"ResourceOffline"} 1071 {"ResourceFailed"}
                        1201 {"GroupOnline"} 1202 {"GroupOffline"} 1205 {"GroupMoved"}
                        1564 {"FailoverStarted"} 1566 {"FailoverCompleted"} default {"Unknown"}
                    }
                    RoleName    = $role
                    SourceNode  = $source
                    TargetNode  = $target
                    ServerName  = $env:COMPUTERNAME
                }
            }
        } catch {}
    } -ArgumentList $startDate, $eventIDs

    foreach ($r in $raw) {
        if ($null -eq $r) { continue }
        $ni = $nodeMap | Where-Object { $_.NodeName -eq $r.PSComputerName } | Select-Object -First 1
        $switches += [PSCustomObject]@{
            TimeCreated = $r.TimeCreated
            EventId     = $r.EventId
            EventType   = $r.EventType
            ClusterName = if ($ni) { $ni.ClusterName } else { "Unknown" }
            ClusterType = if ($ni) { $ni.ClusterType } else { "Unknown" }
            RoleName    = $r.RoleName
            SourceNode  = $r.SourceNode
            TargetNode  = $r.TargetNode
            ReportedBy  = $r.PSComputerName
        }
    }

    foreach ($err in $evtErrors) {
        Write-Host "  BLAD: $($err.TargetObject) - $($err.Exception.Message)" -ForegroundColor Red
        Log "  BLAD: $($err.TargetObject) - $($err.Exception.Message)"
    }
}

# Deduplikacja
$seen   = @{}
$unique = @()
$switches = @($switches | Sort-Object { $_.TimeCreated } -Descending)
foreach ($s in $switches) {
    $key = "$($s.TimeCreated)|$($s.EventId)|$($s.RoleName)|$($s.ClusterName)"
    if (!$seen[$key]) { $seen[$key] = $true; $unique += $s }
}

# ZAPIS DO CSV
$csvPath = "$DataPath\role_switches.csv"
if (Test-Path $csvPath) { Remove-Item $csvPath }
if ($unique.Count -gt 0) {
    $unique | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
} else {
    # Pusty CSV z naglowkiem
    "TimeCreated,EventId,EventType,ClusterName,ClusterType,RoleName,SourceNode,TargetNode,ReportedBy" | Out-File $csvPath -Encoding UTF8
}

Write-Host "`n=== GOTOWE ===" -ForegroundColor Green
Write-Host "role_switches.csv: $($unique.Count) wierszy"
Log "KONIEC: $($unique.Count) zdarzen"
