#Requires -Version 5.1
# =============================================================================
# Initialize-Folders.ps1
# Tworzy wymagane katalogi i przenosi pliki konfiguracyjne do nowej lokalizacji
# Uruchom raz po aktualizacji
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
    $EventLogsPath = $appConfig.paths.eventLogsPath
} else {
    Write-Host "BLAD: Brak pliku app-config.json" -ForegroundColor Red
    exit 1
}

Write-Host "=== Inicjalizacja folderow ===" -ForegroundColor Cyan
Write-Host "BasePath: $BasePath"
Write-Host "DataPath: $DataPath"
Write-Host "LogsPath: $LogsPath"
Write-Host "ConfigPath: $ConfigPath"
Write-Host "EventLogsPath: $EventLogsPath"
Write-Host ""

# Twórz katalogi
$folders = @($BasePath, $DataPath, $LogsPath, $ConfigPath, $EventLogsPath)
foreach ($folder in $folders) {
    if (-not (Test-Path $folder)) {
        Write-Host "Tworzę: $folder" -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    } else {
        Write-Host "Istnieje: $folder" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "=== Przenoszenie plików konfiguracyjnych ===" -ForegroundColor Cyan

# Pliki do przeniesienia z BasePath do ConfigPath
$configFiles = @(
    "clusters.json",
    "serverList_DCI.txt",
    "serverList_Ferryt.txt",
    "serverList_MarketPlanet.txt",
    "serverList_MQ.txt",
    "serverList_FileTransfer.txt",
    "serverList_Klastry.txt",
    "serverList_DMZ.json",
    "config_mq.json",
    "EventLogsConfig.json",
    "fileshare.csv",
    "sql_db_details.csv"
)

foreach ($file in $configFiles) {
    $oldPath = Join-Path $BasePath $file
    $newPath = Join-Path $ConfigPath $file

    # Sprawdź też starą lokalizację clusters.json
    if ($file -eq "clusters.json") {
        $altOldPath = "D:\PROD_REPO_DATA\IIS\Cluster\clusters.json"
        if ((Test-Path $altOldPath) -and (-not (Test-Path $newPath))) {
            Write-Host "Kopiuję: $altOldPath -> $newPath" -ForegroundColor Yellow
            Copy-Item $altOldPath $newPath -Force
        }
    }

    # Sprawdź stare lokalizacje CSV
    if ($file -eq "fileshare.csv") {
        $altOldPath = "D:\PROD_REPO_DATA\IIS\Cluster\data\fileShare.csv"
        if ((Test-Path $altOldPath) -and (-not (Test-Path $newPath))) {
            Write-Host "Kopiuję: $altOldPath -> $newPath" -ForegroundColor Yellow
            Copy-Item $altOldPath $newPath -Force
        }
    }

    if ($file -eq "sql_db_details.csv") {
        $altOldPath = "D:\PROD_REPO_DATA\IIS\Cluster\data\sql_db_details.csv"
        if ((Test-Path $altOldPath) -and (-not (Test-Path $newPath))) {
            Write-Host "Kopiuję: $altOldPath -> $newPath" -ForegroundColor Yellow
            Copy-Item $altOldPath $newPath -Force
        }
    }

    if ((Test-Path $oldPath) -and (-not (Test-Path $newPath))) {
        Write-Host "Przenoszę: $file" -ForegroundColor Yellow
        Move-Item $oldPath $newPath -Force
    } elseif (Test-Path $newPath) {
        Write-Host "Juz istnieje: $file" -ForegroundColor Green
    } else {
        Write-Host "Brak: $file (do utworzenia ręcznie)" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "=== Przenoszenie plików danych ===" -ForegroundColor Cyan

# Pliki danych
$dataFiles = @(
    "serverHealth_DCI.json",
    "serverHealth_Ferryt.json",
    "serverHealth_MarketPlanet.json",
    "serverHealth_MQ.json",
    "serverHealth_FileTransfer.json",
    "serverHealth_Klastry.json",
    "serverHealth_DMZ.json",
    "infra_ClustersWindows.json",
    "infra_UdzialySieciowe.json",
    "infra_InstancjeSQL.json",
    "infra_KolejkiMQ.json",
    "infra_PrzelaczeniaRol.json"
)

$oldDataPath = Join-Path $BasePath "data"
foreach ($file in $dataFiles) {
    $oldPath = Join-Path $oldDataPath $file
    $newPath = Join-Path $DataPath $file

    if ((Test-Path $oldPath) -and ($oldDataPath -ne $DataPath)) {
        Write-Host "Przenoszę dane: $file" -ForegroundColor Yellow
        Move-Item $oldPath $newPath -Force
    }
}

Write-Host ""
Write-Host "=== Inicjalizacja zakończona ===" -ForegroundColor Green
Write-Host ""
Write-Host "Nowa struktura katalogów:" -ForegroundColor Cyan
Write-Host "  $ConfigPath\" -ForegroundColor White
Write-Host "    clusters.json          - konfiguracja klastrów"
Write-Host "    serverList_*.txt       - listy serwerów LAN"
Write-Host "    serverList_DMZ.json    - konfiguracja serwerów DMZ"
Write-Host "    config_mq.json         - konfiguracja serwerów MQ"
Write-Host "    EventLogsConfig.json   - typy logów Event Log"
Write-Host "    fileshare.csv          - dane udziałów sieciowych"
Write-Host "    sql_db_details.csv     - dane instancji SQL"
Write-Host ""
Write-Host "  $DataPath\" -ForegroundColor White
Write-Host "    serverHealth_*.json    - dane kondycji serwerów"
Write-Host "    infra_*.json           - dane infrastruktury"
Write-Host ""
Write-Host "  $LogsPath\" -ForegroundColor White
Write-Host "    ServerHealthMonitor.log - logi skryptów"
Write-Host ""
Write-Host "  $EventLogsPath\" -ForegroundColor White
Write-Host "    *_Application_*.json   - pobrane logi Event Log"
