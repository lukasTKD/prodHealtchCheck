#Requires -Version 5.1
# Skrypt zbiorczy - uruchamia zbieranie danych dla wszystkich grup

$ScriptPath = $PSScriptRoot
$Groups = @("DCI", "Ferryt", "MarketPlanet", "MQ", "FileTransfer", "Klastry")

Write-Host "=== Zbieranie danych dla wszystkich grup ===" -ForegroundColor Cyan
Write-Host ""

foreach ($Group in $Groups) {
    Write-Host ">>> Uruchamiam: $Group" -ForegroundColor Yellow
    & "$ScriptPath\Collect-ServerHealth.ps1" -Group $Group
    Write-Host ""
}

Write-Host "=== Zakonczono zbieranie dla wszystkich grup ===" -ForegroundColor Cyan

[Environment]::Exit(0)
