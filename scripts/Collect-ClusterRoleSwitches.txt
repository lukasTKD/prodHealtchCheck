# Collect-ClusterRoleSwitches.ps1
# Zbiera historie przelaczen rol klastrow SQL i FileShare
# Dane: kiedy rola zatrzymana, kiedy uruchomiona, jaka rola, na jakim serwerze
# Wzor: Get-ClusterStatusReport.ps1 (uzywa -Cluster zamiast Invoke-Command)

# --- SCIEZKI ---
$ScriptDir  = Split-Path $PSScriptRoot -Parent
$appConfig  = [System.IO.File]::ReadAllText("$ScriptDir\app-config.json") | ConvertFrom-Json
$DataPath   = $appConfig.paths.dataPath
$ConfigPath = $appConfig.paths.configPath
$LogsPath   = $appConfig.paths.logsPath

if (!(Test-Path $DataPath)) { New-Item -ItemType Directory -Path $DataPath -Force | Out-Null }
if (!(Test-Path $LogsPath)) { New-Item -ItemType Directory -Path $LogsPath -Force | Out-Null }

# Plik wyjsciowy z konfiguracji
$OutputFile = Join-Path $DataPath $appConfig.outputs.infra.przelaczeniaRol
$LogFile    = "$LogsPath\ServerHealthMonitor.log"
$DaysBack   = 30

function Log($msg) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [ROLE-SWITCH] $msg" | Out-File $LogFile -Append -Encoding UTF8 }

Log "START"

$clustersJson = [System.IO.File]::ReadAllText("$ConfigPath\clusters.json") | ConvertFrom-Json

# Tylko SQL i FileShare — MQ nie maja FailoverClustering
$clusterDefs = @($clustersJson.clusters | Where-Object { $_.cluster_type -ne "MQ" })

if ($clusterDefs.Count -eq 0) {
    Log "Brak klastrow SQL/FileShare"
    @{ LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); DaysBack = $DaysBack; TotalEvents = 0; Switches = @() } |
        ConvertTo-Json -Depth 10 | Out-File $OutputFile -Encoding UTF8 -Force
    exit 0
}

# Krok 1: Pobierz wezly z kazdego klastra (uzywa -Cluster jak w cluster.ps1)
$nodeMap  = @()
$done     = @{}
$allNodes = @()

foreach ($def in $clusterDefs) {
    $type = $def.cluster_type
    foreach ($srv in $def.servers) {
        try {
            $cluster     = Get-Cluster -Name $srv -ErrorAction Stop
            $clusterName = $cluster.Name

            if ($done[$clusterName]) { continue }
            $done[$clusterName] = $true

            $clusterNodes = @(Get-ClusterNode -Cluster $srv -ErrorAction Stop | Select-Object -ExpandProperty Name)
            foreach ($node in $clusterNodes) {
                $nodeMap  += [PSCustomObject]@{ ClusterName = $clusterName; ClusterType = $type; NodeName = $node }
                $allNodes += $node
            }
            Log "  $clusterName ($type): $($clusterNodes.Count) wezlow"
        } catch {
            Log "  FAIL $srv : $($_.Exception.Message)"
        }
    }
}

$allNodes = @($allNodes | Sort-Object -Unique)
Log "Odpytuje $($allNodes.Count) wezlow: $($allNodes -join ', ')"

# Krok 2: Pobierz eventy przelaczen
$eventIDs  = @(1069, 1070, 1071, 1201, 1202, 1205, 1564, 1566)
$startDate = (Get-Date).AddDays(-$DaysBack)
$switches  = @()

if ($allNodes.Count -gt 0) {
    $raw = Invoke-Command -ComputerName $allNodes -ErrorAction SilentlyContinue -ScriptBlock {
        param($startDate, $eventIDs)
        try {
            Get-WinEvent -FilterHashtable @{
                LogName   = 'Microsoft-Windows-FailoverClustering/Operational'
                StartTime = $startDate
                Id        = $eventIDs
            } -ErrorAction SilentlyContinue | ForEach-Object {
                $msg = $_.Message
                $role = ""; $target = ""; $source = ""
                if ($msg -match "Cluster group '([^']+)'")        { $role   = $Matches[1] }
                elseif ($msg -match "Cluster resource '([^']+)'") { $role   = $Matches[1] }
                if ($msg -match "node '([^']+)'")                 { $target = $Matches[1] }
                if ($msg -match "from node '([^']+)'")            { $source = $Matches[1] }

                [PSCustomObject]@{
                    TimeCreated = $_.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                    EventId     = $_.Id
                    EventType   = switch ($_.Id) {
                        1069 { "ResourceOnline" }
                        1070 { "ResourceOffline" }
                        1071 { "ResourceFailed" }
                        1201 { "GroupOnline" }
                        1202 { "GroupOffline" }
                        1205 { "GroupMoved" }
                        1564 { "FailoverStarted" }
                        1566 { "FailoverCompleted" }
                        default { "Unknown" }
                    }
                    RoleName   = $role
                    SourceNode = $source
                    TargetNode = $target
                    ServerName = $env:COMPUTERNAME
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
}

# Deduplikacja i sortowanie
$seen   = @{}
$unique = @()
$switches = @($switches | Sort-Object { $_.TimeCreated } -Descending)
foreach ($s in $switches) {
    $key = "$($s.TimeCreated)|$($s.EventId)|$($s.RoleName)|$($s.ClusterName)"
    if (!$seen[$key]) { $seen[$key] = $true; $unique += $s }
}

@{
    LastUpdate  = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    DaysBack    = $DaysBack
    TotalEvents = $unique.Count
    Switches    = $unique
} | ConvertTo-Json -Depth 10 | Out-File $OutputFile -Encoding UTF8 -Force

Log "KONIEC: $($unique.Count) zdarzen"
