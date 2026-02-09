#Requires -Version 5.1
# Tworzy szablony plikow z listami serwerow dla kazdej grupy

$BasePath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
$Groups = @("DCI", "Ferryt", "MarketPlanet", "MQ", "FileTransfer", "Klastry")

# Utworz katalog jesli nie istnieje
if (-not (Test-Path "$BasePath\data")) {
    New-Item -Path "$BasePath\data" -ItemType Directory -Force | Out-Null
}

foreach ($Group in $Groups) {
    $FilePath = "$BasePath\serverList_$Group.txt"
    if (-not (Test-Path $FilePath)) {
        $Content = @"
# Lista serwerow dla grupy: $Group
# Wpisz nazwy serwerow, kazdy w nowej linii
# Linie zaczynajace sie od # sa ignorowane

"@
        Set-Content -Path $FilePath -Value $Content -Encoding UTF8
        Write-Host "Utworzono: $FilePath" -ForegroundColor Green
    } else {
        Write-Host "Istnieje: $FilePath" -ForegroundColor Yellow
    }
}

Write-Host "`nGotowe! Edytuj pliki serverList_*.txt i dodaj nazwy serwerow." -ForegroundColor Cyan
