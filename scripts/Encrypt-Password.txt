# =============================================================
# Encrypt-Password.ps1
# Skrypt do szyfrowania hasla dla DMZ
# Uruchom w PowerShell ISE lub konsoli PowerShell
# UWAGA: Zaszyfrowane haslo dziala TYLKO na tym samym komputerze
#        i dla tego samego uzytkownika Windows!
# =============================================================

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  SZYFROWANIE HASLA DLA DMZ" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Pobierz haslo od uzytkownika (ukryte wprowadzanie)
$securePassword = Read-Host -Prompt "Wprowadz haslo do zaszyfrowania" -AsSecureString

# Konwersja na zaszyfrowany string
$encryptedPassword = ConvertFrom-SecureString -SecureString $securePassword

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  ZASZYFROWANE HASLO:" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host $encryptedPassword -ForegroundColor Yellow
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Skopiuj powyzszy ciag i wklej do pliku serverList_DMZ.json" -ForegroundColor Cyan
Write-Host "w polu 'password' dla odpowiedniej grupy." -ForegroundColor Cyan
Write-Host ""
Write-Host "PAMIETAJ: To haslo zadziala TYLKO na tym komputerze" -ForegroundColor Red
Write-Host "          i dla tego samego uzytkownika Windows!" -ForegroundColor Red
Write-Host ""

# Opcjonalnie: skopiuj do schowka
$copyToClipboard = Read-Host "Skopiowac do schowka? (T/N)"
if ($copyToClipboard -eq "T" -or $copyToClipboard -eq "t") {
    $encryptedPassword | Set-Clipboard
    Write-Host "Skopiowano do schowka!" -ForegroundColor Green
}
