# --- KONFIGURACJA ---
# Wpisz tutaj nazwy swoich serwerów
$TargetServers = @("SRVMQ1", "SRVMQ2", "SRVMQ3", "SRVMQ4", "SRVWMQ1","SRVWMQ2") 

# Ścieżka pliku wynikowego
$CsvPath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck\config\all_mq_queue_list.csv"

# --- LOGIKA ---
$Dir = Split-Path $CsvPath -Parent
if (!(Test-Path $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }

Write-Host "Rozpoczynam zbieranie danych z: $($TargetServers -join ', ')" -ForegroundColor Cyan

$Results = Invoke-Command -ComputerName $TargetServers -ScriptBlock {
    $LocalResults = @()
    $ServerName = $env:COMPUTERNAME
    
    # 1. Wykrywanie Managerów
    $RunningQMs = @()
    try {
        $dspmqOutput = dspmq 2>$null
        if ($dspmqOutput) {
            foreach ($line in $dspmqOutput) {
                # Regex łapiący nazwę i status (z obsługą PL znaków)
                if ($line -match 'QMNAME\s*\(\s*(?<qm>.*?)\s*\).*?STATUS\s*\(\s*(?<stat>.*?)\s*\)') {
                    $qmName = $Matches['qm'].Trim()
                    $status = $Matches['stat']
                    if ($status -match 'Running|Dzia') {
                        $RunningQMs += $qmName
                    }
                }
            }
        }
    } catch { Write-Warning "[$ServerName] Błąd dspmq" }

    if ($RunningQMs.Count -gt 0) {
        Write-Warning "[$ServerName] Znaleziono managery: $($RunningQMs -join ', ')"
    }

    # 2. Pobieranie WSZYSTKICH kolejek
    foreach ($QM in $RunningQMs) {
        # ZMIANA: Pobieramy gwiazdkę (*) zamiast TEST.Q.*
        $Output = "DISPLAY QLOCAL(*)" | runmqsc $QM 2>$null
        
        if ($Output) {
            foreach ($Line in $Output) {
                if ($Line -match 'QUEUE\s*\(\s*(?<qname>.*?)\s*\)') {
                    $qName = $Matches['qname'].Trim()
                    
                    # FILTR: Pomijamy kolejki systemowe IBM (SYSTEM.* i AMQ.*)
                    # Jeśli chcesz widzieć systemowe, usuń ten if
                    if ($qName -notmatch '^SYSTEM\.|^AMQ\.') {
                        $LocalResults += [PSCustomObject]@{
                            QManager = $QM
                            Kolejka  = $qName
                            Serwer   = $ServerName
                        }
                    }
                }
            }
        }
    }
    return $LocalResults
}

# 3. Zapis do CSV
if ($Results) {
    $Results | Select-Object QManager, Kolejka, Serwer | 
    Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Delimiter ","
    
    Write-Host "SUKCES! Plik zapisano: $CsvPath" -ForegroundColor Green
    Write-Host "Znaleziono łącznie kolejek: $(($Results | Measure-Object).Count)" -ForegroundColor Cyan
} else {
    Write-Error "Brak danych. Skrypt połączył się, ale nie znalazł żadnych kolejek (innych niż systemowe)."
}
