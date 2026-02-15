#Requires -Version 5.1
# =============================================================================
# Collect-MQData.ps1
# Scalony skrypt: kolejki MQ + status klastrow WMQ
# Pobiera dane z clusters.json dla cluster_type: WMQ
# Wykonanie zdalne (Invoke-Command) rownolegle
# =============================================================================
param(
    [int]$ThrottleLimit = 50
)

$ScriptPath = $PSScriptRoot
$ConfigFile = Join-Path (Split-Path $ScriptPath -Parent) "app-config.json"

if (Test-Path $ConfigFile) {
    $appConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $DataPath = $appConfig.paths.dataPath
    $LogsPath = $appConfig.paths.logsPath
    $ConfigPath = $appConfig.paths.configPath
    $OutputKolejki = Join-Path $DataPath $appConfig.outputs.infra.kolejkiMQ
    $OutputClusters = Join-Path $DataPath $appConfig.outputs.clusters.wmq
} else {
    $BasePath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
    $DataPath = "$BasePath\data"
    $LogsPath = "$BasePath\logs"
    $ConfigPath = "$BasePath\config"
    $OutputKolejki = "$DataPath\infra_KolejkiMQ.json"
    $OutputClusters = "$DataPath\infra_ClustersWMQ.json"
}

@($DataPath, $LogsPath) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

$LogPath = "$LogsPath\ServerHealthMonitor.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [MQ] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

Write-Log "=== START Collect-MQData ==="
$startTime = Get-Date

# Wczytaj konfiguracje z clusters.json
$ClustersConfigPath = "$ConfigPath\clusters.json"
if (-not (Test-Path $ClustersConfigPath)) {
    Write-Log "BLAD: Brak pliku clusters.json"
    $emptyResult = @{
        LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CollectionDuration = "0"
        TotalServers = 0
        Servers = @()
    }
    $emptyResult | ConvertTo-Json -Depth 10 | Out-File $OutputKolejki -Encoding UTF8
    @{
        LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CollectionDuration = "0"
        TotalClusters = 0
        OnlineCount = 0
        FailedCount = 0
        Clusters = @()
    } | ConvertTo-Json -Depth 10 | Out-File $OutputClusters -Encoding UTF8
    exit 1
}

$clustersData = Get-Content $ClustersConfigPath -Raw | ConvertFrom-Json

# Wyodrebnij klastry WMQ
$wmqClusters = @($clustersData.clusters | Where-Object { $_.cluster_type -eq "WMQ" })

if ($wmqClusters.Count -eq 0) {
    Write-Log "Brak klastrow WMQ w konfiguracji"
    @{
        LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CollectionDuration = "0"
        TotalServers = 0
        Servers = @()
    } | ConvertTo-Json -Depth 10 | Out-File $OutputKolejki -Encoding UTF8
    @{
        LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CollectionDuration = "0"
        TotalClusters = 0
        OnlineCount = 0
        FailedCount = 0
        Clusters = @()
    } | ConvertTo-Json -Depth 10 | Out-File $OutputClusters -Encoding UTF8
    exit 0
}

# Zbuduj mape serwer -> klaster oraz liste serwerow
$serverClusterMap = @{}
$targetServers = @()

foreach ($cluster in $wmqClusters) {
    foreach ($srv in $cluster.servers) {
        $serverClusterMap[$srv] = $cluster.cluster_name
        $targetServers += $srv
    }
}
$targetServers = @($targetServers | Select-Object -Unique)

Write-Log "Serwery MQ ($($targetServers.Count)): $($targetServers -join ', ')"

# ScriptBlock wykonywany zdalnie - pobiera wszystkie dane MQ
$ScriptBlock = {
    $result = @{
        ServerName = $env:COMPUTERNAME
        IPAddress = ""
        QueueManagers = @()
    }

    # Pobierz IP
    try {
        $ips = Get-NetIPAddress -AddressFamily IPv4 -Type Unicast -ErrorAction SilentlyContinue |
               Where-Object { $_.InterfaceAlias -notmatch "Loopback|Pseudo" -and $_.IPAddress -notmatch "^169\." }
        if ($ips) {
            $result.IPAddress = if ($ips -is [array]) { $ips[0].IPAddress } else { $ips.IPAddress }
        }
    } catch {
        $result.IPAddress = "N/A"
    }

    # Pobierz QueueManagery
    try {
        $dspmqOutput = dspmq 2>$null
        if ($dspmqOutput) {
            foreach ($line in $dspmqOutput) {
                if ($line -match 'QMNAME\s*\(\s*(?<qm>[^\)]+)\s*\).*?STATUS\s*\(\s*(?<stat>[^\)]+)\s*\)') {
                    $qmName = $Matches['qm'].Trim()
                    $status = $Matches['stat'].Trim()

                    # Normalizacja statusu z uwzglednieniem Standby
                    $normalizedStatus = switch -Regex ($status) {
                        'Running|Dzia'           { "Running" }
                        'Standby|As standby'     { "Standby" }
                        'Starting|Urucham'       { "Starting" }
                        'Quiescing|Wygasz'       { "Quiescing" }
                        default                  { "Stopped" }
                    }

                    $port = ""
                    $queues = @()

                    # Pobierz dane tylko jesli QM dziala (Running)
                    if ($normalizedStatus -eq "Running") {
                        # Pobierz port
                        try {
                            $lsData = "DISPLAY LSSTATUS(*) PORT" | runmqsc $qmName 2>$null
                            foreach ($l in $lsData) {
                                if ($l -match 'PORT\s*\(\s*(\d+)\s*\)') {
                                    $port = $Matches[1]
                                    break
                                }
                            }
                        } catch {}

                        # Pobierz kolejki ze statusem (bez systemowych)
                        try {
                            # Pobierz nazwy kolejek
                            $qData = "DISPLAY QLOCAL(*) GET PUT" | runmqsc $qmName 2>$null
                            $currentQueue = $null

                            foreach ($q in $qData) {
                                if ($q -match 'QUEUE\s*\(\s*([^\)]+)\s*\)') {
                                    $qn = $Matches[1].Trim()
                                    if ($qn -notmatch '^SYSTEM\.|^AMQ\.') {
                                        $currentQueue = @{
                                            QueueName = $qn
                                            GetEnabled = $true
                                            PutEnabled = $true
                                            CurrentDepth = 0
                                        }
                                        $queues += $currentQueue
                                    } else {
                                        $currentQueue = $null
                                    }
                                }
                                if ($currentQueue) {
                                    if ($q -match 'GET\s*\(\s*([^\)]+)\s*\)') {
                                        $currentQueue.GetEnabled = ($Matches[1].Trim() -eq "ENABLED")
                                    }
                                    if ($q -match 'PUT\s*\(\s*([^\)]+)\s*\)') {
                                        $currentQueue.PutEnabled = ($Matches[1].Trim() -eq "ENABLED")
                                    }
                                }
                            }

                            # Pobierz CURDEPTH dla kolejek
                            $qsData = "DISPLAY QSTATUS(*) CURDEPTH" | runmqsc $qmName 2>$null
                            foreach ($qs in $qsData) {
                                if ($qs -match 'QUEUE\s*\(\s*([^\)]+)\s*\)') {
                                    $qsName = $Matches[1].Trim()
                                    $matchingQueue = $queues | Where-Object { $_.QueueName -eq $qsName }
                                    if ($matchingQueue -and $qs -match 'CURDEPTH\s*\(\s*(\d+)\s*\)') {
                                        $matchingQueue.CurrentDepth = [int]$Matches[1]
                                    }
                                }
                            }
                        } catch {}
                    }

                    $result.QueueManagers += @{
                        QueueManager = $qmName
                        Status = $normalizedStatus
                        Port = $port
                        Queues = $queues
                    }
                }
            }
        }
    } catch {}

    $result
}

# Wykonaj rownolegle na wszystkich serwerach
$rawResults = Invoke-Command -ComputerName $targetServers -ScriptBlock $ScriptBlock -ThrottleLimit $ThrottleLimit -ErrorAction SilentlyContinue -ErrorVariable errs

# Przetwarzanie wynikow
$servers = [System.Collections.ArrayList]::new()
$okServers = @()

foreach ($r in $rawResults) {
    if ($r.ServerName) {
        $srv = $r.PSComputerName
        $okServers += $srv

        [void]$servers.Add(@{
            ServerName = $r.ServerName
            ClusterName = $serverClusterMap[$srv]
            IPAddress = $r.IPAddress
            Error = $null
            QueueManagers = @($r.QueueManagers)
        })

        $qmCount = ($r.QueueManagers | Measure-Object).Count
        $queueCount = ($r.QueueManagers | ForEach-Object { $_.Queues.Count } | Measure-Object -Sum).Sum
        Write-Log "OK: $($r.ServerName) ($qmCount QM, $queueCount kolejek)"
    }
}

# Serwery ktore nie odpowiedzialy
foreach ($srv in $targetServers) {
    if ($srv -notin $okServers) {
        [void]$servers.Add(@{
            ServerName = $srv
            ClusterName = $serverClusterMap[$srv]
            IPAddress = ""
            Error = "Niedostepny"
            QueueManagers = @()
        })
        Write-Log "FAIL: $srv"
    }
}

$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

# === ZAPIS 1: Kolejki MQ (infra_KolejkiMQ.json) ===
@{
    LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $duration.ToString()
    TotalServers = $servers.Count
    Servers = @($servers)
} | ConvertTo-Json -Depth 10 | Out-File $OutputKolejki -Encoding UTF8 -Force

Write-Log "Zapisano: $OutputKolejki"

# === ZAPIS 2: Klastry MQ (infra_ClustersWMQ.json) ===
# Agreguj dane do struktury klastrow
$clusterData = @{}

foreach ($s in $servers) {
    $clusterName = $s.ClusterName
    if (-not $clusterName) { continue }

    if (-not $clusterData[$clusterName]) {
        $clusterData[$clusterName] = @{
            ClusterName = $clusterName
            ClusterType = "WMQ"
            Error = $null
            Nodes = @()
            Roles = @()
        }
    }

    # Dodaj wezel
    $nodeState = if ($s.Error) { "Down" } else { "Up" }
    $clusterData[$clusterName].Nodes += @{
        Name = $s.ServerName.ToUpper()
        State = $nodeState
        IPAddresses = $s.IPAddress
    }

    # Dodaj role (QueueManagery)
    if (-not $s.Error) {
        foreach ($qm in $s.QueueManagers) {
            $roleState = if ($qm.Status -eq "Running") { "Online" } else { "Offline" }
            $clusterData[$clusterName].Roles += @{
                Name = $qm.QueueManager
                State = $roleState
                OwnerNode = $s.ServerName.ToUpper()
                IPAddresses = $s.IPAddress
                Port = $qm.Port
            }
        }
    }
}

# Oblicz statystyki
$clusters = @($clusterData.Values)
$onlineCount = 0
$failedCount = 0

foreach ($c in $clusters) {
    $upNodes = @($c.Nodes | Where-Object { $_.State -eq "Up" }).Count
    if ($upNodes -eq 0) {
        $c.Error = "Wszystkie wezly klastra niedostepne"
        $failedCount++
    } else {
        $onlineCount++
    }
}

@{
    LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $duration.ToString()
    TotalClusters = $clusters.Count
    OnlineCount = $onlineCount
    FailedCount = $failedCount
    Clusters = $clusters
} | ConvertTo-Json -Depth 10 | Out-File $OutputClusters -Encoding UTF8 -Force

Write-Log "Zapisano: $OutputClusters"
Write-Log "=== KONIEC Collect-MQData (${duration}s) ==="
