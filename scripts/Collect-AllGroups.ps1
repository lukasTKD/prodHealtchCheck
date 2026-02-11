#Requires -Version 5.1
# Skrypt zbiorczy - uruchamia zbieranie danych dla wszystkich grup

$ScriptPath = $PSScriptRoot
$BasePath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
$LogPath = "$BasePath\ServerHealthMonitor.log"
$LogMaxAgeHours = 48

$Groups = @("DCI", "Ferryt", "MarketPlanet", "MQ", "FileTransfer", "Klastry")

# Funkcja logowania z rollowaniem
function Write-Log {
    param([string]$Message)

    if (Test-Path $LogPath) {
        $logFile = Get-Item $LogPath
        if ($logFile.LastWriteTime -lt (Get-Date).AddHours(-$LogMaxAgeHours)) {
            $archiveName = "$BasePath\ServerHealthMonitor_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            Move-Item $LogPath $archiveName -Force
        }
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [ALL] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

Write-Log "=== START zbierania dla wszystkich grup ==="

# Grupy LAN
foreach ($Group in $Groups) {
    Write-Log "Uruchamiam: $Group"
    & "$ScriptPath\Collect-ServerHealth.ps1" -Group $Group
}

# Grupa DMZ
Write-Log "Uruchamiam: DMZ"
& "$ScriptPath\Collect-ServerHealth-DMZ.ps1"

Write-Log "=== KONIEC zbierania dla wszystkich grup ==="

exit 0
