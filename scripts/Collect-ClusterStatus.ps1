#Requires -Version 5.1
# =============================================================================
# Collect-ClusterStatus.ps1
# Zbiera status klastrów Windows i zapisuje do JSON
# Uruchamiany co 5 minut (razem z Collect-AllGroups.ps1)
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

$OutputPath = "$DataPath\infra_ClustersWindows.json"
$LogPath = "$LogsPath\ServerHealthMonitor.log"
$LogMaxAgeHours = 48

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
    "$timestamp [CLUSTERS] $Message" | Out-File $LogPath -Append -Encoding UTF8
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
    $configRaw = Get-Content $ClustersConfigPath -Raw
    $config = $configRaw | ConvertFrom-Json
} catch {
    Write-Log "BLAD: Nie mozna sparsowac clusters.json - $($_.Exception.Message)"
    exit 1
}

# Walidacja struktury konfiguracji - plik uzywa "clusterNames" (plaska tablica nazw klastrow)
$clusterNames = @($config.clusterNames)
Write-Log "Wczytano konfiguracje: $($clusterNames.Count) klastrow"
Write-Log "DEBUG: Dostepne property w config: $( ($config | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name) -join ', ' )"

if ($clusterNames.Count -eq 0) {
    Write-Log "BLAD: Brak klastrow w konfiguracji (property 'clusterNames' pusta lub nie istnieje)"
    exit 1
}

# Zbierz liste klastrow
$clusterList = [System.Collections.ArrayList]::new()
foreach ($name in $clusterNames) {
    Write-Log "  Klaster: $name"
    [void]$clusterList.Add(@{ FQDN = $name; Type = 'Windows' })
}

Write-Log "Laczna liczba klastrow do odpytania: $($clusterList.Count)"

Write-Log "START zbierania statusu klastrow ($($clusterList.Count) klastrow)"
$startTime = Get-Date
$clusterResults = [System.Collections.ArrayList]::new()

# --- Upewnij się że moduł FailoverClusters jest dostępny ---
try {
    Import-Module FailoverClusters -ErrorAction Stop
    Write-Log "Modul FailoverClusters zaladowany"
} catch {
    Write-Log "BLAD KRYTYCZNY: Nie mozna zaladowac modulu FailoverClusters - $($_.Exception.Message)"
    Write-Log "Zainstaluj feature: Install-WindowsFeature RSAT-Clustering-PowerShell"
    # Zapisz pusty wynik
    @{
        LastUpdate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CollectionDuration = 0
        TotalClusters      = 0
        OnlineCount        = 0
        FailedCount        = 0
        Clusters           = @()
        Error              = "Modul FailoverClusters niedostepny"
    } | ConvertTo-Json -Depth 10 | Out-File $OutputPath -Encoding UTF8 -Force
    exit 1
}

# --- Zbieranie danych z klastrów (sekwencyjnie - niezawodne) ---
Write-Log "Rozpoczynam odpytywanie $($clusterList.Count) klastrow..."

foreach ($cluster in $clusterList) {
    $clusterFQDN = $cluster.FQDN
    $clusterType = $cluster.Type
    Write-Log "Odpytuje klaster: $clusterFQDN (typ: $clusterType)"

    try {
        # Pobierz nazwę klastra
        $clusterObj = Get-Cluster -Name $clusterFQDN -ErrorAction Stop
        $clusterName = $clusterObj.Name

        # Pobierz węzły - jedno zapytanie
        $rawNodes = @(Get-ClusterNode -Cluster $clusterFQDN -ErrorAction Stop)

        # Pobierz interfejsy sieciowe - jedno zapytanie dla wszystkich węzłów
        $allInterfaces = @()
        try {
            $allInterfaces = @(Get-ClusterNetworkInterface -Cluster $clusterFQDN -ErrorAction SilentlyContinue)
        } catch {}

        # Buduj listę węzłów z adresami IP (lokalne przetwarzanie bez RPC)
        $nodes = @($rawNodes | ForEach-Object {
            $nodeName = $_.Name
            $nodeIPs = ($allInterfaces | Where-Object { $_.Node -eq $nodeName } |
                        ForEach-Object { $_.Address }) -join ", "
            @{
                Name        = $nodeName
                State       = $_.State.ToString()
                NodeWeight  = $_.NodeWeight
                DynamicWeight = $_.DynamicWeight
                IPAddresses = $(if ($nodeIPs) { $nodeIPs } else { "N/A" })
            }
        })

        # Pobierz role i zasoby - dwa zapytania zamiast N
        $rawRoles = @(Get-ClusterGroup -Cluster $clusterFQDN -ErrorAction Stop)
        $allResources = @()
        try {
            $allResources = @(Get-ClusterResource -Cluster $clusterFQDN -ErrorAction SilentlyContinue)
        } catch {}

        # Batch pobieranie parametrów IP - filtruj tylko IP Address resources
        $ipResources = @($allResources | Where-Object { $_.ResourceType -eq "IP Address" })
        $ipParams = @{}

        $ipResources | ForEach-Object {
            try {
                $addr = (Get-ClusterParameter -InputObject $_ -Name Address -ErrorAction SilentlyContinue).Value
                if ($addr) {
                    $ownerGroup = $_.OwnerGroup.ToString()
                    if ($ipParams.ContainsKey($ownerGroup)) {
                        $ipParams[$ownerGroup] += ", $addr"
                    } else {
                        $ipParams[$ownerGroup] = $addr
                    }
                }
            } catch {}
        }

        $roles = @($rawRoles | ForEach-Object {
            $roleName = $_.Name
            @{
                Name        = $roleName
                State       = $_.State.ToString()
                OwnerNode   = $_.OwnerNode.ToString()
                IPAddresses = $(if ($ipParams.ContainsKey($roleName)) { $ipParams[$roleName] } else { "" })
            }
        })

        $result = @{
            Success     = $true
            ClusterName = $clusterName
            FQDN        = $clusterFQDN
            ClusterType = $clusterType
            Status      = "Online"
            Nodes       = $nodes
            Roles       = $roles
            Error       = $null
        }
        Write-Log "OK: $clusterName ($clusterType) - $($nodes.Count) wezlow, $($roles.Count) rol"
        [void]$clusterResults.Add($result)
    }
    catch {
        $errMsg = $_.Exception.Message
        Write-Log "FAIL: $clusterFQDN - $errMsg"
        [void]$clusterResults.Add(@{
            Success     = $false
            ClusterName = $clusterFQDN -replace '\..*$', ''
            FQDN        = $clusterFQDN
            ClusterType = $clusterType
            Status      = "Error"
            Nodes       = @()
            Roles       = @()
            Error       = $errMsg
        })
    }
}

# --- Zapisz wynik ---
$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
$onlineCount = @($clusterResults | Where-Object { $_.Status -eq "Online" }).Count

$output = @{
    LastUpdate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $duration
    TotalClusters      = $clusterResults.Count
    OnlineCount        = $onlineCount
    FailedCount        = $clusterResults.Count - $onlineCount
    Clusters           = @($clusterResults)
}

$output | ConvertTo-Json -Depth 10 | Out-File $OutputPath -Encoding UTF8 -Force

Write-Log "KONIEC: ${duration}s (OK: $onlineCount, FAIL: $($clusterResults.Count - $onlineCount))"
