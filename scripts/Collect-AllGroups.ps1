#Requires -Version 5.1
# Skrypt zbiorczy - uruchamia zbieranie danych dla wszystkich grup RÓWNOLEGLE

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

Write-Log "=== START zbierania dla wszystkich grup (PARALLEL) ==="
$startTime = Get-Date

# OPTYMALIZACJA: Równoległe wykonanie wszystkich grup LAN + DMZ + Klastry
$jobs = [System.Collections.Generic.List[object]]::new()

# Uruchom wszystkie grupy LAN równolegle
foreach ($Group in $Groups) {
    $jobs.Add((Start-Job -FilePath "$ScriptPath\Collect-ServerHealth.ps1" -ArgumentList $Group -Name "LAN_$Group"))
}

# Uruchom DMZ równolegle
$jobs.Add((Start-Job -FilePath "$ScriptPath\Collect-ServerHealth-DMZ.ps1" -Name "DMZ"))

# Uruchom Klastry równolegle
$jobs.Add((Start-Job -FilePath "$ScriptPath\Collect-ClusterStatus.ps1" -Name "Clusters"))

# Czekaj na wszystkie zadania
Write-Log "Uruchomiono $($jobs.Count) zadań równolegle, czekam na zakończenie..."
$jobs | Wait-Job | Out-Null

# Zbierz wyniki i zaloguj
foreach ($job in $jobs) {
    $status = if ($job.State -eq 'Completed') { "OK" } else { "FAIL ($($job.State))" }
    Write-Log "Zakończono: $($job.Name) - $status"
    Remove-Job $job -Force
}

$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
Write-Log "=== KONIEC zbierania dla wszystkich grup (${duration}s) ==="

exit 0
