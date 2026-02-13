$TargetServers = @("SRVMQ1","SRVMQ2") 
$CsvPath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data\HAA_IBM_WMQ_12_role_status.csv"

# G³ówna komenda wykonywana zdalnie
$Results = Invoke-Command -ComputerName $TargetServers -ScriptBlock {
    # 1. Pobierz nazwê wêz³a
    $NodeName = $env:COMPUTERNAME
    
    # 2. Uruchom dspmq i sparsuj wyniki
    try {
        $mqData = dspmq 2>$null
        
        if ($mqData) {
            $mqData | ForEach-Object {
                # Regex z obs³ug¹ spacji dla bezpieczeñstwa
                if ($_ -match 'QMNAME\s*\(\s*(?<name>.*?)\s*\)\s+STATUS\s*\(\s*(?<state>.*?)\s*\)') {
                    
                    $qmName = $Matches['name'].Trim()
                    $rawState = $Matches['state'].Trim()

                    # --- NAPRAWA POLSKICH ZNAKÓW (POPRAWIONA) ---
                    # Wzorzec 'c[ye]' ³apie koñcówki "cy" oraz "ce"
                    # Pasuje do: Dzia³aj¹cy, Dzia³aj¹ce, Dzia#@!cy, Dziaaaaace itp.
                    $cleanState = $rawState -replace 'Dzia.+?c[ye]', 'Dzia³aj¹cy'
                    # --------------------------------------------
                    
                    # --- POBIERANIE PORTU (do kolumny IPAddresses) ---
                    $Port = "Brak/Nieaktywny"
                    
                    # Sprawdzamy czy status to Running lub nasz naprawiony Dzia³aj¹cy
                    if ($cleanState -match 'Running|Dzia') {
                        # Pytamy o status listenera
                        $listenerData = "DISPLAY LSSTATUS(*) PORT" | runmqsc $qmName 2>$null
                        
                        $foundPorts = @()
                        if ($listenerData) {
                            foreach ($lLine in $listenerData) {
                                # Regex wyci¹gaj¹cy numer portu
                                if ($lLine -match 'PORT\s*\(\s*(?<p>\d+)\s*\)') {
                                    $foundPorts += $Matches['p']
                                }
                            }
                        }
                        
                        # Jeœli znaleziono porty, ³¹czymy je œrednikami
                        if ($foundPorts.Count -gt 0) {
                            $Port = $foundPorts -join ";"
                        }
                    }

                    [PSCustomObject]@{
                        Name        = $qmName
                        State       = $cleanState
                        OwnerNode   = $NodeName
                        IPAddresses = $Port  # Port w kolumnie IP
                    }
                }
            }
        }
    }
    catch {
        [PSCustomObject]@{
            Name        = "ERROR"
            State       = "B³¹d po³¹czenia lub brak MQ"
            OwnerNode   = $NodeName
            IPAddresses = "Brak"
        }
    }
}

# 3. Zapisz wyniki do CSV
$Results | Select-Object Name, State, OwnerNode, IPAddresses |
Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Delimiter ","

Write-Host "Plik zapisano w: $CsvPath" -ForegroundColor Green


############################################################################

$TargetServers = @("SRVMQ3","SRVMQ4") 
$CsvPath = "D:\PROD_REPO_DATA\IIS\Cluster\data\HAA_IBM_WMQ_34_role_status.csv"

# G³ówna komenda wykonywana zdalnie
$Results = Invoke-Command -ComputerName $TargetServers -ScriptBlock {
    # 1. Pobierz nazwê wêz³a
    $NodeName = $env:COMPUTERNAME
    
    # 2. Uruchom dspmq i sparsuj wyniki
    try {
        $mqData = dspmq 2>$null
        
        if ($mqData) {
            $mqData | ForEach-Object {
                # Regex z obs³ug¹ spacji dla bezpieczeñstwa
                if ($_ -match 'QMNAME\s*\(\s*(?<name>.*?)\s*\)\s+STATUS\s*\(\s*(?<state>.*?)\s*\)') {
                    
                    $qmName = $Matches['name'].Trim()
                    $rawState = $Matches['state'].Trim()

                    # --- NAPRAWA POLSKICH ZNAKÓW (POPRAWIONA) ---
                    # Wzorzec 'c[ye]' ³apie koñcówki "cy" oraz "ce"
                    # Pasuje do: Dzia³aj¹cy, Dzia³aj¹ce, Dzia#@!cy, Dziaaaaace itp.
                    $cleanState = $rawState -replace 'Dzia.+?c[ye]', 'Dzia³aj¹cy'
                    # --------------------------------------------
                    
                    # --- POBIERANIE PORTU (do kolumny IPAddresses) ---
                    $Port = "Brak/Nieaktywny"
                    
                    # Sprawdzamy czy status to Running lub nasz naprawiony Dzia³aj¹cy
                    if ($cleanState -match 'Running|Dzia') {
                        # Pytamy o status listenera
                        $listenerData = "DISPLAY LSSTATUS(*) PORT" | runmqsc $qmName 2>$null
                        
                        $foundPorts = @()
                        if ($listenerData) {
                            foreach ($lLine in $listenerData) {
                                # Regex wyci¹gaj¹cy numer portu
                                if ($lLine -match 'PORT\s*\(\s*(?<p>\d+)\s*\)') {
                                    $foundPorts += $Matches['p']
                                }
                            }
                        }
                        
                        # Jeœli znaleziono porty, ³¹czymy je œrednikami
                        if ($foundPorts.Count -gt 0) {
                            $Port = $foundPorts -join ";"
                        }
                    }

                    [PSCustomObject]@{
                        Name        = $qmName
                        State       = $cleanState
                        OwnerNode   = $NodeName
                        IPAddresses = $Port  # Port w kolumnie IP
                    }
                }
            }
        }
    }
    catch {
        [PSCustomObject]@{
            Name        = "ERROR"
            State       = "B³¹d po³¹czenia lub brak MQ"
            OwnerNode   = $NodeName
            IPAddresses = "Brak"
        }
    }
}

# 3. Zapisz wyniki do CSV
$Results | Select-Object Name, State, OwnerNode, IPAddresses |
Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Delimiter ","

Write-Host "Plik zapisano w: $CsvPath" -ForegroundColor Green

############################################################################

$TargetServers = @("anowmq1","anowmq2") 
$CsvPath = "D:\PROD_REPO_DATA\IIS\Cluster\data\FileTransfer_MQ_role_status.csv"

# G³ówna komenda wykonywana zdalnie
$Results = Invoke-Command -ComputerName $TargetServers -ScriptBlock {
    # 1. Pobierz nazwê wêz³a
    $NodeName = $env:COMPUTERNAME
    
    # 2. Uruchom dspmq i sparsuj wyniki
    try {
        $mqData = dspmq 2>$null
        
        if ($mqData) {
            $mqData | ForEach-Object {
                # Regex z obs³ug¹ spacji dla bezpieczeñstwa
                if ($_ -match 'QMNAME\s*\(\s*(?<name>.*?)\s*\)\s+STATUS\s*\(\s*(?<state>.*?)\s*\)') {
                    
                    $qmName = $Matches['name'].Trim()
                    $rawState = $Matches['state'].Trim()

                    # --- NAPRAWA POLSKICH ZNAKÓW (POPRAWIONA) ---
                    # Wzorzec 'c[ye]' ³apie koñcówki "cy" oraz "ce"
                    # Pasuje do: Dzia³aj¹cy, Dzia³aj¹ce, Dzia#@!cy, Dziaaaaace itp.
                    $cleanState = $rawState -replace 'Dzia.+?c[ye]', 'Dzia³aj¹cy'
                    # --------------------------------------------
                    
                    # --- POBIERANIE PORTU (do kolumny IPAddresses) ---
                    $Port = "Brak/Nieaktywny"
                    
                    # Sprawdzamy czy status to Running lub nasz naprawiony Dzia³aj¹cy
                    if ($cleanState -match 'Running|Dzia') {
                        # Pytamy o status listenera
                        $listenerData = "DISPLAY LSSTATUS(*) PORT" | runmqsc $qmName 2>$null
                        
                        $foundPorts = @()
                        if ($listenerData) {
                            foreach ($lLine in $listenerData) {
                                # Regex wyci¹gaj¹cy numer portu
                                if ($lLine -match 'PORT\s*\(\s*(?<p>\d+)\s*\)') {
                                    $foundPorts += $Matches['p']
                                }
                            }
                        }
                        
                        # Jeœli znaleziono porty, ³¹czymy je œrednikami
                        if ($foundPorts.Count -gt 0) {
                            $Port = $foundPorts -join ";"
                        }
                    }

                    [PSCustomObject]@{
                        Name        = $qmName
                        State       = $cleanState
                        OwnerNode   = $NodeName
                        IPAddresses = $Port  # Port w kolumnie IP
                    }
                }
            }
        }
    }
    catch {
        [PSCustomObject]@{
            Name        = "ERROR"
            State       = "B³¹d po³¹czenia lub brak MQ"
            OwnerNode   = $NodeName
            IPAddresses = "Brak"
        }
    }
}

# 3. Zapisz wyniki do CSV
$Results | Select-Object Name, State, OwnerNode, IPAddresses |
Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Delimiter ","

Write-Host "Plik zapisano w: $CsvPath" -ForegroundColor Green