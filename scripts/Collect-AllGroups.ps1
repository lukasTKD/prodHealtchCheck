#Requires -Version 5.1
# =============================================================================
# Collect-AllGroups.ps1
# Skrypt zbiorczy - uruchamia zbieranie danych dla wszystkich grup
# =============================================================================

$ScriptPath = $PSScriptRoot
$BasePath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
$LogsPath = "$BasePath\logs"

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

# Grupy LAN
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

# Status klastrów Windows (co 5 min razem z kondycją serwerów)
Write-Log "Uruchamiam: Collect-ClusterStatus.ps1"
try {
    & "$ScriptPath\Collect-ClusterStatus.ps1"
    Write-Log "Zakonczono: Collect-ClusterStatus.ps1"
} catch {
    Write-Log "BLAD: Collect-ClusterStatus.ps1 - $($_.Exception.Message)"
}

Write-Log "=== KONIEC zbierania dla wszystkich grup ==="

exit 0
