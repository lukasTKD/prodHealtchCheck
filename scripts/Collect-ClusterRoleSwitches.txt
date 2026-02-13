#Requires -Version 5.1
# =============================================================================
# Collect-ClusterRoleSwitches.ps1
# Zbiera historie przelaczen rol klastrow Windows (failover/failback)
# Odpytuje TYLKO klastry SQL i FileShare (MQ nie sa klastrami Windows)
# Zdarzenia z Microsoft-Windows-FailoverClustering/Operational
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

$OutputPath = "$DataPath\infra_PrzelaczeniaRol.json"
$LogPath    = "$LogsPath\ServerHealthMonitor.log"
$DaysBack   = 30

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts [ROLE-SWITCH] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

# --- Wczytaj konfiguracje ---
$possiblePaths = @(
    "$ConfigPath\clusters.json",
    "D:\PROD_REPO_DATA\IIS\Cluster\clusters.json"
)
$ClustersConfigPath = $null
foreach ($p in $possiblePaths) {
    if (Test-Path $p) { $ClustersConfigPath = $p; break }
}
if (-not $ClustersConfigPath) {
    Write-Log "BLAD: Brak pliku clusters.json"
    @{ LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); DaysBack = $DaysBack; TotalEvents = 0; Switches = @() } |
        ConvertTo-Json -Depth 10 | Out-File $OutputPath -Encoding UTF8 -Force
    exit 1
}

$config = Get-Content $ClustersConfigPath -Raw | ConvertFrom-Json

# TYLKO klastry SQL i FileShare (MQ nie maja FailoverClustering)
$clusterServers = @($config.clusters |
    Where-Object { $_.cluster_type -eq "SQL" -or $_.cluster_type -eq "FileShare" } |
    ForEach-Object {
        $type = $_.cluster_type
        foreach ($srv in $_.servers) {
            [PSCustomObject]@{ Server = $srv; ClusterType = $type }
        }
    })

if ($clusterServers.Count -eq 0) {
    Write-Log "Brak serwerow SQL/FileShare w konfiguracji"
    @{ LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); DaysBack = $DaysBack; TotalEvents = 0; Switches = @() } |
        ConvertTo-Json -Depth 10 | Out-File $OutputPath -Encoding UTF8 -Force
    exit 0
}

Write-Log "=== START zbierania przelaczen rol ==="
$startTime = Get-Date

# Krok 1: Pobierz nazwy klastrow i wezly (przez Invoke-Command per serwer)
$clusterNodeMap = [System.Collections.ArrayList]::new()
$processedClusters = @{}

foreach ($cs in $clusterServers) {
    $srv  = $cs.Server
    $type = $cs.ClusterType

    try {
        $info = Invoke-Command -ComputerName $srv -ErrorAction Stop -ScriptBlock {
            $cl = Get-Cluster -ErrorAction Stop
            $nodes = @(Get-ClusterNode | Select-Object -ExpandProperty Name)
            [PSCustomObject]@{
                ClusterName = $cl.Name
                Nodes       = $nodes
            }
        }

        if ($processedClusters.ContainsKey($info.ClusterName)) {
            Write-Log "  Pomijam $srv (klaster $($info.ClusterName) juz przetworzony)"
            continue
        }
        $processedClusters[$info.ClusterName] = $true

        foreach ($node in $info.Nodes) {
            [void]$clusterNodeMap.Add([PSCustomObject]@{
                ClusterName = $info.ClusterName
                ClusterType = $type
                NodeName    = $node
            })
        }
        Write-Log "  OK: $($info.ClusterName) ($type) - $($info.Nodes.Count) wezlow"

    } catch {
        Write-Log "  FAIL: $srv - $($_.Exception.Message)"
    }
}

# Krok 2: Odpytaj eventy na unikalnych wezlach
$uniqueNodes = @($clusterNodeMap | ForEach-Object { $_.NodeName } | Sort-Object -Unique)
Write-Log "Odpytuje $($uniqueNodes.Count) unikalnych wezlow..."

$relevantEventIDs = @(1069, 1070, 1071, 1201, 1202, 1205, 1564, 1566)
$startDate = (Get-Date).AddDays(-$DaysBack)

$allSwitches = [System.Collections.ArrayList]::new()

if ($uniqueNodes.Count -gt 0) {
    $rawResults = Invoke-Command -ComputerName $uniqueNodes -ErrorAction SilentlyContinue -ErrorVariable remoteErrors -ScriptBlock {
        param($startDate, $eventIDs)

        $results = @()
        try {
            $events = Get-WinEvent -FilterHashtable @{
                LogName   = 'Microsoft-Windows-FailoverClustering/Operational'
                StartTime = $startDate
                Id        = $eventIDs
            } -ErrorAction SilentlyContinue

            foreach ($event in $events) {
                $eventType = switch ($event.Id) {
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

                $message    = $event.Message
                $roleName   = ""
                $targetNode = ""
                $sourceNode = ""

                if ($message -match "Cluster group '([^']+)'")    { $roleName   = $Matches[1] }
                elseif ($message -match "Cluster resource '([^']+)'") { $roleName = $Matches[1] }
                elseif ($message -match "group ([^\s]+)")          { $roleName   = $Matches[1] }

                if ($message -match "node '([^']+)'")       { $targetNode = $Matches[1] }
                elseif ($message -match "to node ([^\s]+)")  { $targetNode = $Matches[1] }

                if ($message -match "from node '([^']+)'")   { $sourceNode = $Matches[1] }
                elseif ($message -match "from ([^\s]+) to")  { $sourceNode = $Matches[1] }

                $results += [PSCustomObject]@{
                    TimeCreated = $event.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                    EventId     = $event.Id
                    EventType   = $eventType
                    RoleName    = $roleName
                    SourceNode  = $sourceNode
                    TargetNode  = $targetNode
                    Message     = ($message -replace '[\x00-\x1f]', ' ').Trim()
                    ServerName  = $env:COMPUTERNAME
                }
            }
        } catch { }

        $results
    } -ArgumentList $startDate, $relevantEventIDs

    # Przetworz wyniki
    foreach ($result in $rawResults) {
        if ($null -eq $result) { continue }

        $serverName = $result.PSComputerName
        if (-not $serverName) { $serverName = $result.ServerName }

        $nodeInfo = $clusterNodeMap | Where-Object { $_.NodeName -eq $serverName } | Select-Object -First 1

        [void]$allSwitches.Add([PSCustomObject]@{
            TimeCreated = $result.TimeCreated
            EventId     = $result.EventId
            EventType   = $result.EventType
            ClusterName = if ($nodeInfo) { $nodeInfo.ClusterName } else { "Unknown" }
            ClusterType = if ($nodeInfo) { $nodeInfo.ClusterType } else { "Unknown" }
            RoleName    = $result.RoleName
            SourceNode  = $result.SourceNode
            TargetNode  = $result.TargetNode
            ReportedBy  = $serverName
            Message     = $result.Message
        })
    }

    foreach ($err in $remoteErrors) {
        Write-Log "  WARN: $($err.TargetObject) - $($err.Exception.Message)"
    }
}

# Sortuj po dacie (najnowsze najpierw) i deduplikuj
$allSwitches = @($allSwitches | Sort-Object -Property { $_.TimeCreated } -Descending)

$uniqueSwitches = [System.Collections.ArrayList]::new()
$seen = @{}
foreach ($sw in $allSwitches) {
    $key = "$($sw.TimeCreated)|$($sw.EventId)|$($sw.RoleName)|$($sw.ClusterName)"
    if (-not $seen.ContainsKey($key)) {
        $seen[$key] = $true
        [void]$uniqueSwitches.Add($sw)
    }
}

# --- Zapisz wynik ---
$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

@{
    LastUpdate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $duration
    DaysBack           = $DaysBack
    TotalEvents        = $uniqueSwitches.Count
    Switches           = @($uniqueSwitches)
} | ConvertTo-Json -Depth 10 | Out-File $OutputPath -Encoding UTF8 -Force

Write-Log "=== KONIEC: ${duration}s ($($uniqueSwitches.Count) zdarzen) ==="
