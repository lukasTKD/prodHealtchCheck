#Requires -Version 5.1
# =============================================================================
# Collect-ClusterData.ps1
# Scalony skrypt: status klastrow Windows + historia przelaczen rol
# Pobiera dane z clusters.json dla cluster_type: SQL, FileShare
# Wykonanie zdalne (Invoke-Command) rownolegle
# =============================================================================
param(
    [int]$ThrottleLimit = 50,
    [int]$DaysBack = 30
)

$ScriptPath = $PSScriptRoot
$ConfigFile = Join-Path (Split-Path $ScriptPath -Parent) "app-config.json"

if (Test-Path $ConfigFile) {
    $appConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $DataPath = $appConfig.paths.dataPath
    $LogsPath = $appConfig.paths.logsPath
    $ConfigPath = $appConfig.paths.configPath
    $OutputSQL = Join-Path $DataPath $appConfig.outputs.clusters.sql
    $OutputFileShare = Join-Path $DataPath $appConfig.outputs.clusters.fileShare
    $OutputSwitches = Join-Path $DataPath $appConfig.outputs.infra.przelaczeniaRol
} else {
    $BasePath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
    $DataPath = "$BasePath\data"
    $LogsPath = "$BasePath\logs"
    $ConfigPath = "$BasePath\config"
    $OutputSQL = "$DataPath\infra_ClustersSQL.json"
    $OutputFileShare = "$DataPath\infra_ClustersFileShare.json"
    $OutputSwitches = "$DataPath\infra_PrzelaczeniaRol.json"
}

@($DataPath, $LogsPath) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

$LogPath = "$LogsPath\ServerHealthMonitor.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [CLUSTERS] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

Write-Log "=== START Collect-ClusterData ==="
$startTime = Get-Date

# Wczytaj konfiguracje klastrow
$ClustersConfigPath = "$ConfigPath\clusters.json"
if (-not (Test-Path $ClustersConfigPath)) {
    Write-Log "BLAD: Brak pliku clusters.json"
    $emptyCluster = @{
        LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CollectionDuration = "0"
        TotalClusters = 0
        OnlineCount = 0
        FailedCount = 0
        Clusters = @()
    }
    $emptyCluster | ConvertTo-Json -Depth 10 | Out-File $OutputSQL -Encoding UTF8
    $emptyCluster | ConvertTo-Json -Depth 10 | Out-File $OutputFileShare -Encoding UTF8
    @{
        LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        DaysBack = $DaysBack
        TotalEvents = 0
        Switches = @()
    } | ConvertTo-Json -Depth 10 | Out-File $OutputSwitches -Encoding UTF8
    exit 1
}

$clustersData = Get-Content $ClustersConfigPath -Raw | ConvertFrom-Json

# Wyodrebnij klastry SQL i FileShare (klastry Windows z FailoverClustering)
$clusterDefs = @($clustersData.clusters | Where-Object { $_.cluster_type -in @("SQL", "FileShare") })

if ($clusterDefs.Count -eq 0) {
    Write-Log "Brak klastrow SQL/FileShare w konfiguracji"
    $emptyCluster = @{
        LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CollectionDuration = "0"
        TotalClusters = 0
        OnlineCount = 0
        FailedCount = 0
        Clusters = @()
    }
    $emptyCluster | ConvertTo-Json -Depth 10 | Out-File $OutputSQL -Encoding UTF8
    $emptyCluster | ConvertTo-Json -Depth 10 | Out-File $OutputFileShare -Encoding UTF8
    @{
        LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        DaysBack = $DaysBack
        TotalEvents = 0
        Switches = @()
    } | ConvertTo-Json -Depth 10 | Out-File $OutputSwitches -Encoding UTF8
    exit 0
}

# Zbierz wszystkie serwery i ich typy/nazwy klastrow
$serverTypeMap = @{}
$serverClusterNameMap = @{}
$allServers = @()

foreach ($def in $clusterDefs) {
    foreach ($srv in $def.servers) {
        $serverTypeMap[$srv] = $def.cluster_type
        $serverClusterNameMap[$srv] = $def.cluster_name
        $allServers += $srv
    }
}
$allServers = @($allServers | Select-Object -Unique)

Write-Log "Serwery klastrow ($($allServers.Count)): $($allServers -join ', ')"

# ============================================================================
# ScriptBlock - pobiera dane klastra i eventy przelaczen
# ============================================================================
$eventIDs = @(1069, 1070, 1071, 1201, 1202, 1205, 1564, 1566)
$eventStartDate = (Get-Date).AddDays(-$DaysBack)

$ScriptBlock = {
    param($eventIDs, $eventStartDate)

    $result = @{
        ServerName = $env:COMPUTERNAME
        ClusterName = $null
        ClusterData = $null
        Events = @()
        Error = $null
    }

    try {
        # Pobierz dane klastra
        Import-Module FailoverClusters -ErrorAction Stop

        $cluster = Get-Cluster -ErrorAction Stop
        $result.ClusterName = $cluster.Name

        # Pobierz wezly
        $nodes = @(Get-ClusterNode -ErrorAction Stop | ForEach-Object {
            $node = $_
            $ipAddresses = "N/A"
            try {
                $nodeNetworks = Get-ClusterNetworkInterface -Node $node.Name -ErrorAction SilentlyContinue
                $ipAddresses = ($nodeNetworks | ForEach-Object { $_.Address }) -join ", "
                if (-not $ipAddresses) { $ipAddresses = "N/A" }
            } catch {}

            @{
                Name = $node.Name
                State = $node.State.ToString()
                IPAddresses = $ipAddresses
            }
        })

        # Pobierz role
        $roles = @(Get-ClusterGroup -ErrorAction Stop | ForEach-Object {
            $role = $_
            $ipAddr = "N/A"

            try {
                $resources = Get-ClusterResource -ErrorAction SilentlyContinue | Where-Object { $_.OwnerGroup -eq $role.Name }
                $ips = @($resources | Where-Object { $_.ResourceType -eq "IP Address" } | ForEach-Object {
                    try { (Get-ClusterParameter -InputObject $_ -Name Address -ErrorAction SilentlyContinue).Value } catch {}
                }) | Where-Object { $_ }
                if ($ips) { $ipAddr = $ips -join ", " }
            } catch {}

            # DNS dla rol SQL
            $displayName = $role.Name
            if ($role.Name -like "*SQL*" -and $ipAddr -and $ipAddr -ne "N/A") {
                $sqlIP = ($ipAddr -split ", ")[0]
                try { $displayName = ([System.Net.Dns]::GetHostEntry($sqlIP)).HostName } catch {}
            }

            @{
                Name = $displayName
                State = $role.State.ToString()
                OwnerNode = $role.OwnerNode.ToString()
                IPAddresses = $ipAddr
            }
        })

        $result.ClusterData = @{
            Nodes = $nodes
            Roles = $roles
        }

        # Pobierz eventy przelaczen
        try {
            $events = Get-WinEvent -FilterHashtable @{
                LogName = 'Microsoft-Windows-FailoverClustering/Operational'
                StartTime = $eventStartDate
                Id = $eventIDs
            } -ErrorAction SilentlyContinue

            foreach ($evt in $events) {
                $msg = $evt.Message
                $role = ""; $target = ""; $source = ""

                if ($msg -match "Cluster group '([^']+)'") { $role = $Matches[1] }
                elseif ($msg -match "Cluster resource '([^']+)'") { $role = $Matches[1] }
                if ($msg -match "node '([^']+)'") { $target = $Matches[1] }
                if ($msg -match "from node '([^']+)'") { $source = $Matches[1] }

                $eventType = switch ($evt.Id) {
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

                $result.Events += @{
                    TimeCreated = $evt.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                    EventId = $evt.Id
                    EventType = $eventType
                    RoleName = $role
                    SourceNode = $source
                    TargetNode = $target
                }
            }
        } catch {}

    } catch {
        $result.Error = $_.Exception.Message
    }

    $result
}

# Wykonaj rownolegle
$rawResults = Invoke-Command -ComputerName $allServers -ScriptBlock $ScriptBlock -ArgumentList $eventIDs, $eventStartDate -ThrottleLimit $ThrottleLimit -ErrorAction SilentlyContinue -ErrorVariable errs

# ============================================================================
# Przetwarzanie wynikow
# ============================================================================
$sqlClusters = @()
$fshareClusters = @()
$allSwitches = @()
$processedClusters = @{}

foreach ($r in $rawResults) {
    if (-not $r.ServerName) { continue }

    $srv = $r.PSComputerName
    $clusterType = $serverTypeMap[$srv]
    $configClusterName = $serverClusterNameMap[$srv]

    if ($r.Error) {
        Write-Log "FAIL: $srv - $($r.Error)"

        # Dodaj jako bledny klaster jesli nie byl juz przetworzony
        $clusterKey = "$srv-error"
        if (-not $processedClusters[$clusterKey]) {
            $processedClusters[$clusterKey] = $true

            $errorCluster = @{
                ClusterName = $configClusterName
                ClusterType = $clusterType
                Error = $r.Error
                Nodes = @()
                Roles = @()
            }

            if ($clusterType -eq "SQL") { $sqlClusters += $errorCluster }
            elseif ($clusterType -eq "FileShare") { $fshareClusters += $errorCluster }
        }
        continue
    }

    $clusterName = $r.ClusterName
    if (-not $clusterName) { continue }

    # Deduplikacja klastrow (ten sam klaster z roznych wezlow)
    if ($processedClusters[$clusterName]) {
        Write-Log "Pomijam duplikat: $clusterName (z $srv)"
        continue
    }
    $processedClusters[$clusterName] = $true

    $clusterObj = @{
        ClusterName = $clusterName
        ConfigName = $configClusterName
        ClusterType = $clusterType
        Error = $null
        Nodes = @($r.ClusterData.Nodes)
        Roles = @($r.ClusterData.Roles)
    }

    if ($clusterType -eq "SQL") { $sqlClusters += $clusterObj }
    elseif ($clusterType -eq "FileShare") { $fshareClusters += $clusterObj }

    Write-Log "OK: $clusterName ($clusterType) - $($r.ClusterData.Nodes.Count) wezlow, $($r.ClusterData.Roles.Count) rol"

    # Zbierz eventy przelaczen
    foreach ($evt in $r.Events) {
        $allSwitches += @{
            TimeCreated = $evt.TimeCreated
            EventId = $evt.EventId
            EventType = $evt.EventType
            ClusterName = $clusterName
            ClusterType = $clusterType
            RoleName = $evt.RoleName
            SourceNode = $evt.SourceNode
            TargetNode = $evt.TargetNode
            ReportedBy = $r.ServerName
        }
    }
}

# Obsluz serwery ktore nie odpowiedzialy
$okServers = @($rawResults | ForEach-Object { $_.PSComputerName })
foreach ($srv in $allServers) {
    if ($srv -notin $okServers) {
        $clusterType = $serverTypeMap[$srv]
        $configClusterName = $serverClusterNameMap[$srv]
        Write-Log "FAIL: $srv - Niedostepny"

        $errorCluster = @{
            ClusterName = $configClusterName
            ClusterType = $clusterType
            Error = "Niedostepny"
            Nodes = @()
            Roles = @()
        }

        if ($clusterType -eq "SQL") { $sqlClusters += $errorCluster }
        elseif ($clusterType -eq "FileShare") { $fshareClusters += $errorCluster }
    }
}

# Deduplikacja eventow i sortowanie
$seen = @{}
$uniqueSwitches = @()
$sortedSwitches = @($allSwitches | Sort-Object { $_.TimeCreated } -Descending)

foreach ($s in $sortedSwitches) {
    $key = "$($s.TimeCreated)|$($s.EventId)|$($s.RoleName)|$($s.ClusterName)"
    if (-not $seen[$key]) {
        $seen[$key] = $true
        $uniqueSwitches += $s
    }
}

$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

# ============================================================================
# ZAPIS WYNIKOW
# ============================================================================

# SQL Clusters
$sqlOnline = @($sqlClusters | Where-Object { -not $_.Error }).Count
@{
    LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $duration.ToString()
    TotalClusters = $sqlClusters.Count
    OnlineCount = $sqlOnline
    FailedCount = $sqlClusters.Count - $sqlOnline
    Clusters = $sqlClusters
} | ConvertTo-Json -Depth 10 | Out-File $OutputSQL -Encoding UTF8 -Force

Write-Log "Zapisano: $OutputSQL ($($sqlClusters.Count) klastrow)"

# FileShare Clusters
$fshareOnline = @($fshareClusters | Where-Object { -not $_.Error }).Count
@{
    LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $duration.ToString()
    TotalClusters = $fshareClusters.Count
    OnlineCount = $fshareOnline
    FailedCount = $fshareClusters.Count - $fshareOnline
    Clusters = $fshareClusters
} | ConvertTo-Json -Depth 10 | Out-File $OutputFileShare -Encoding UTF8 -Force

Write-Log "Zapisano: $OutputFileShare ($($fshareClusters.Count) klastrow)"

# Role Switches
@{
    LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    DaysBack = $DaysBack
    TotalEvents = $uniqueSwitches.Count
    Switches = $uniqueSwitches
} | ConvertTo-Json -Depth 10 | Out-File $OutputSwitches -Encoding UTF8 -Force

Write-Log "Zapisano: $OutputSwitches ($($uniqueSwitches.Count) zdarzen)"
Write-Log "=== KONIEC Collect-ClusterData (${duration}s) ==="
