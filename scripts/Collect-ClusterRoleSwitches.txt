# Collect-ClusterRoleSwitches.ps1
# Prosty skrypt — eventy przelaczen z klastrow SQL i FileShare

# --- SCIEZKI ---
$ScriptDir  = Split-Path $PSScriptRoot -Parent
$appConfig  = Get-Content "$ScriptDir\app-config.json" -Raw | ConvertFrom-Json
$DataPath   = $appConfig.paths.dataPath
$ConfigPath = $appConfig.paths.configPath
$LogsPath   = $appConfig.paths.logsPath

if (!(Test-Path $DataPath)) { New-Item -ItemType Directory -Path $DataPath -Force | Out-Null }
if (!(Test-Path $LogsPath)) { New-Item -ItemType Directory -Path $LogsPath -Force | Out-Null }

$OutputFile = "$DataPath\infra_PrzelaczeniaRol.json"
$LogFile    = "$LogsPath\ServerHealthMonitor.log"
$DaysBack   = 30

function Log($msg) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [ROLE-SWITCH] $msg" | Out-File $LogFile -Append -Encoding UTF8 }

Log "START"

$clustersJson = Get-Content "$ConfigPath\clusters.json" -Raw | ConvertFrom-Json

# Tylko SQL i FileShare — MQ nie maja FailoverClustering
$clusterServers = @($clustersJson.clusters | Where-Object { $_.cluster_type -ne "MQ" })

if ($clusterServers.Count -eq 0) {
    Log "Brak klastrow SQL/FileShare"
    @{ LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); DaysBack = $DaysBack; TotalEvents = 0; Switches = @() } |
        ConvertTo-Json -Depth 10 | Out-File $OutputFile -Encoding UTF8 -Force
    exit 0
}

# Krok 1: Pobierz wezly — jedno Invoke-Command na pierwszy serwer z kazdego klastra
$nodeMap  = @()
$done     = @{}
$allNodes = @()

# Zbierz po jednym serwerze z kazdego klastra (unikamy duplikatow od razu)
$firstServers = @()
$srvTypeMap   = @{}
foreach ($def in $clusterServers) {
    $srv = $def.servers[0]
    $firstServers += $srv
    $srvTypeMap[$srv] = $def.cluster_type
}

# Jedno rownolegle wywolanie
$clusterInfos = Invoke-Command -ComputerName $firstServers -ErrorAction SilentlyContinue -ErrorVariable nodeErrors -ScriptBlock {
    [PSCustomObject]@{
        ClusterName = (Get-Cluster).Name
        Nodes       = @(Get-ClusterNode | Select-Object -ExpandProperty Name)
    }
}

foreach ($info in $clusterInfos) {
    $originSrv = $info.PSComputerName
    $type = $srvTypeMap[$originSrv]
    if ($done[$info.ClusterName]) { continue }
    $done[$info.ClusterName] = $true

    foreach ($node in $info.Nodes) {
        $nodeMap  += [PSCustomObject]@{ ClusterName = $info.ClusterName; ClusterType = $type; NodeName = $node }
        $allNodes += $node
    }
    Log "  $($info.ClusterName) ($type): $($info.Nodes.Count) wezlow"
}
foreach ($err in $nodeErrors) { Log "  FAIL: $($err.TargetObject) - $($err.Exception.Message)" }

$allNodes = @($allNodes | Sort-Object -Unique)
Log "Odpytuje $($allNodes.Count) wezlow..."

# Krok 2: Pobierz eventy
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
                if ($msg -match "Cluster group '([^']+)'")     { $role   = $Matches[1] }
                elseif ($msg -match "Cluster resource '([^']+)'") { $role = $Matches[1] }
                if ($msg -match "node '([^']+)'")        { $target = $Matches[1] }
                if ($msg -match "from node '([^']+)'")   { $source = $Matches[1] }

                [PSCustomObject]@{
                    TimeCreated = $_.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                    EventId     = $_.Id
                    EventType   = switch ($_.Id) { 1069 {"ResourceOnline"} 1070 {"ResourceOffline"} 1071 {"ResourceFailed"} 1201 {"GroupOnline"} 1202 {"GroupOffline"} 1205 {"GroupMoved"} 1564 {"FailoverStarted"} 1566 {"FailoverCompleted"} default {"Unknown"} }
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
}

# Deduplikacja
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
