#Requires -Version 5.1
# =============================================================================
# Collect-ClusterRoleSwitches.ps1
# Zbiera historię przełączeń ról klastrów Windows (failover/failback)
# Uruchamiany raz dziennie
# Odczytuje zdarzenia z Microsoft-Windows-FailoverClustering/Operational
# =============================================================================

$ScriptPath = $PSScriptRoot
$ConfigFile = Join-Path (Split-Path $ScriptPath -Parent) "app-config.json"

# Wczytaj konfigurację
if (Test-Path $ConfigFile) {
    $appConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $BasePath = $appConfig.paths.basePath
    $DataPath = $appConfig.paths.dataPath
    $LogsPath = $appConfig.paths.logsPath
    $ConfigPath = $appConfig.paths.configPath
} else {
    $BasePath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
    $DataPath = "$BasePath\data"
    $LogsPath = "$BasePath\logs"
    $ConfigPath = "$BasePath\config"
}

# Upewnij się że katalogi istnieją
@($DataPath, $LogsPath) | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }
}

$OutputPath = "$DataPath\infra_PrzelaczeniaRol.json"
$LogPath = "$LogsPath\ServerHealthMonitor.log"
$LogMaxAgeHours = 48

# Ile dni wstecz szukać zdarzeń (domyślnie 30 dni)
$DaysBack = 30

$ErrorActionPreference = "Continue"

function Write-Log {
    param([string]$Message)
    if (Test-Path $LogPath) {
        $logFile = Get-Item $LogPath
        if ($logFile.LastWriteTime -lt (Get-Date).AddHours(-$LogMaxAgeHours)) {
            $archiveName = "$LogsPath\ServerHealthMonitor_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            Move-Item $LogPath $archiveName -Force
        }
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [ROLE-SWITCH] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

# --- Wczytaj konfigurację klastrów ---
# Sprawdź kilka możliwych lokalizacji pliku clusters.json
$possiblePaths = @(
    "$ConfigPath\clusters.json",
    "$BasePath\clusters.json",
    "D:\PROD_REPO_DATA\IIS\Cluster\clusters.json"
)

$ClustersConfigPath = $null
foreach ($path in $possiblePaths) {
    if (Test-Path $path) {
        $ClustersConfigPath = $path
        break
    }
}

if (-not $ClustersConfigPath) {
    Write-Log "BLAD: Brak pliku konfiguracji clusters.json. Sprawdzono:"
    foreach ($path in $possiblePaths) {
        Write-Log "  - $path"
    }
    exit 1
}

Write-Log "Uzywam konfiguracji: $ClustersConfigPath"

try {
    $config = Get-Content $ClustersConfigPath -Raw | ConvertFrom-Json
} catch {
    Write-Log "BLAD: Nie mozna sparsowac clusters.json - $($_.Exception.Message)"
    exit 1
}

# Plik uzywa "clusterNames" (plaska tablica nazw klastrow)
$clusterNames = @($config.clusterNames)
Write-Log "Wczytano konfiguracje: $($clusterNames.Count) klastrow"

if ($clusterNames.Count -eq 0) {
    Write-Log "BLAD: Brak klastrow w konfiguracji (property 'clusterNames' pusta lub nie istnieje)"
    Write-Log "DEBUG: Dostepne property w config: $( ($config | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name) -join ', ' )"
    exit 1
}

# Zbierz wszystkie węzły klastrów
$clusterNodes = [System.Collections.ArrayList]::new()
foreach ($clusterName in $clusterNames) {
    Write-Log "Pobieranie wezlow klastra: $clusterName"
    try {
        $nodes = @(Get-ClusterNode -Cluster $clusterName -ErrorAction Stop | Select-Object -ExpandProperty Name)
        foreach ($node in $nodes) {
            [void]$clusterNodes.Add(@{
                ClusterFQDN = $clusterName
                ClusterType = 'Windows'
                NodeName    = $node
            })
        }
        Write-Log "  OK: $clusterName - $($nodes.Count) wezlow"
    } catch {
        Write-Log "WARN: Nie mozna pobrac wezlow klastra $clusterName - $($_.Exception.Message)"
    }
}

Write-Log "START zbierania przelaczen rol ($($clusterNodes.Count) wezlow z $($clusterNames.Count) klastrow)"
$startTime = Get-Date

# Event IDs dla przełączeń ról w klastrze Windows:
# 1069 - Cluster resource came online
# 1070 - Cluster resource went offline
# 1071 - Cluster resource failed
# 1205 - Cluster group moved to another node (failover)
# 1201 - Cluster group came online
# 1202 - Cluster group went offline
# 1564 - Role failover started
# 1566 - Role failover completed

$relevantEventIDs = @(1069, 1070, 1071, 1201, 1202, 1205, 1564, 1566)

$allSwitches = [System.Collections.ArrayList]::new()
$startDate = (Get-Date).AddDays(-$DaysBack)

# ScriptBlock do zdalnego pobierania zdarzeń
$scriptBlock = {
    param($startDate, $eventIDs)

    $results = @()

    try {
        # Pobierz zdarzenia z logu FailoverClustering
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

            # Parsuj wiadomość żeby wyciągnąć nazwę roli/zasobu i węzeł
            $message = $event.Message
            $roleName = ""
            $targetNode = ""
            $sourceNode = ""

            # Różne wzorce dla różnych typów zdarzeń
            if ($message -match "Cluster group '([^']+)'") {
                $roleName = $Matches[1]
            } elseif ($message -match "Cluster resource '([^']+)'") {
                $roleName = $Matches[1]
            } elseif ($message -match "group ([^\s]+)") {
                $roleName = $Matches[1]
            }

            if ($message -match "node '([^']+)'") {
                $targetNode = $Matches[1]
            } elseif ($message -match "to node ([^\s]+)") {
                $targetNode = $Matches[1]
            }

            if ($message -match "from node '([^']+)'") {
                $sourceNode = $Matches[1]
            } elseif ($message -match "from ([^\s]+) to") {
                $sourceNode = $Matches[1]
            }

            $results += @{
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
    } catch {
        # Brak zdarzeń lub błąd - zwróć pustą tablicę
    }

    $results
}

# Pobierz unikalne węzły
$uniqueNodes = @($clusterNodes | ForEach-Object { $_.NodeName } | Sort-Object -Unique)

if ($uniqueNodes.Count -gt 0) {
    Write-Log "Odpytuje $($uniqueNodes.Count) unikalnych wezlow..."

    # Wykonaj równolegle na wszystkich węzłach
    $rawResults = Invoke-Command -ComputerName $uniqueNodes -ScriptBlock $scriptBlock `
        -ArgumentList $startDate, $relevantEventIDs `
        -ErrorAction SilentlyContinue -ErrorVariable remoteErrors

    foreach ($result in $rawResults) {
        if ($result -is [hashtable] -or $result -is [System.Collections.Specialized.OrderedDictionary]) {
            # Znajdź informacje o klastrze dla tego węzła
            $nodeInfo = $clusterNodes | Where-Object { $_.NodeName -eq $result.ServerName } | Select-Object -First 1

            [void]$allSwitches.Add(@{
                TimeCreated = $result.TimeCreated
                EventId     = $result.EventId
                EventType   = $result.EventType
                ClusterName = $(if ($nodeInfo) { $nodeInfo.ClusterFQDN -replace '\..*$', '' } else { "Unknown" })
                ClusterType = $(if ($nodeInfo) { $nodeInfo.ClusterType } else { "Unknown" })
                RoleName    = $result.RoleName
                SourceNode  = $result.SourceNode
                TargetNode  = $result.TargetNode
                ReportedBy  = $result.ServerName
                Message     = $result.Message
            })
        } elseif ($result -is [array]) {
            foreach ($r in $result) {
                if ($r -is [hashtable] -or $r -is [System.Collections.Specialized.OrderedDictionary]) {
                    $nodeInfo = $clusterNodes | Where-Object { $_.NodeName -eq $r.ServerName } | Select-Object -First 1

                    [void]$allSwitches.Add(@{
                        TimeCreated = $r.TimeCreated
                        EventId     = $r.EventId
                        EventType   = $r.EventType
                        ClusterName = $(if ($nodeInfo) { $nodeInfo.ClusterFQDN -replace '\..*$', '' } else { "Unknown" })
                        ClusterType = $(if ($nodeInfo) { $nodeInfo.ClusterType } else { "Unknown" })
                        RoleName    = $r.RoleName
                        SourceNode  = $r.SourceNode
                        TargetNode  = $r.TargetNode
                        ReportedBy  = $r.ServerName
                        Message     = $r.Message
                    })
                }
            }
        }
    }

    # Loguj błędy
    foreach ($err in $remoteErrors) {
        Write-Log "WARN: $($err.TargetObject) - $($err.Exception.Message)"
    }
}

# Sortuj po dacie (najnowsze pierwsze) i usuń duplikaty
$allSwitches = @($allSwitches | Sort-Object -Property TimeCreated -Descending)

# Usuń duplikaty (to samo zdarzenie może być zgłoszone przez różne węzły)
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

$output = @{
    LastUpdate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $duration
    DaysBack           = $DaysBack
    TotalEvents        = $uniqueSwitches.Count
    Switches           = @($uniqueSwitches)
}

$output | ConvertTo-Json -Depth 10 | Out-File $OutputPath -Encoding UTF8 -Force

Write-Log "KONIEC: ${duration}s ($($uniqueSwitches.Count) zdarzen przelaczen)"
