#Requires -Version 5.1
# =============================================================================
# Collect-AllGroups.ps1
# Skrypt zbiorczy - uruchamia zbieranie danych dla wszystkich grup
# =============================================================================

$ScriptPath = $PSScriptRoot
$ConfigFile = Join-Path (Split-Path $ScriptPath -Parent) "app-config.json"

# Wczytaj konfigurację
if (Test-Path $ConfigFile) {
    $appConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $BasePath = $appConfig.paths.basePath
    $LogsPath = $appConfig.paths.logsPath
} else {
    $BasePath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
    $LogsPath = "$BasePath\logs"
}

# Upewnij się że katalog logów istnieje
if (-not (Test-Path $LogsPath)) {
    New-Item -ItemType Directory -Path $LogsPath -Force | Out-Null
}

$LogPath = "$LogsPath\ServerHealthMonitor.log"
$LogMaxAgeHours = 48

$Groups = @("DCI", "Ferryt", "MarketPlanet", "MQ", "FileTransfer", "Klastry")

# Funkcja logowania z rollowaniem
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
    "$timestamp [ALL] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

Write-Log "=== START zbierania dla wszystkich grup ==="
Write-Log "Konfiguracja: BasePath=$BasePath, LogsPath=$LogsPath"

# Grupy LAN - ServerHealth
foreach ($Group in $Groups) {
    Write-Log "Uruchamiam: Collect-ServerHealth.ps1 -Group $Group"
    try {
        & "$ScriptPath\Collect-ServerHealth.ps1" -Group $Group
        Write-Log "Zakonczono: Collect-ServerHealth.ps1 -Group $Group"
    } catch {
        Write-Log "BLAD: Collect-ServerHealth.ps1 -Group $Group - $($_.Exception.Message)"
    }
}

# Grupa DMZ
Write-Log "Uruchamiam: Collect-ServerHealth-DMZ.ps1"
try {
    & "$ScriptPath\Collect-ServerHealth-DMZ.ps1"
    Write-Log "Zakonczono: Collect-ServerHealth-DMZ.ps1"
} catch {
    Write-Log "BLAD: Collect-ServerHealth-DMZ.ps1 - $($_.Exception.Message)"
}

# Klastry Windows (SQL, FileShare) + historia przelaczen rol
Write-Log "Uruchamiam: Collect-ClusterData.ps1"
try {
    & "$ScriptPath\Collect-ClusterData.ps1"
    Write-Log "Zakonczono: Collect-ClusterData.ps1"
} catch {
    Write-Log "BLAD: Collect-ClusterData.ps1 - $($_.Exception.Message)"
}

# Dane MQ (kolejki + klastry WMQ)
Write-Log "Uruchamiam: Collect-MQData.ps1"
try {
    & "$ScriptPath\Collect-MQData.ps1"
    Write-Log "Zakonczono: Collect-MQData.ps1"
} catch {
    Write-Log "BLAD: Collect-MQData.ps1 - $($_.Exception.Message)"
}

# Dane infrastruktury (instancje SQL + udzialy sieciowe)
Write-Log "Uruchamiam: Collect-InfraData.ps1"
try {
    & "$ScriptPath\Collect-InfraData.ps1"
    Write-Log "Zakonczono: Collect-InfraData.ps1"
} catch {
    Write-Log "BLAD: Collect-InfraData.ps1 - $($_.Exception.Message)"
}

Write-Log "=== KONIEC zbierania dla wszystkich grup ==="

exit 0
