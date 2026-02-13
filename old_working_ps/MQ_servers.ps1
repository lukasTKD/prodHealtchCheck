# Lista serwerów do sprawdzenia (wprowadŸ tutaj swoje nazwy)
$TargetServers = @("SRVMQ1", "SRVMQ2")

# Œcie¿ka zapisu pliku CSV (zgodnie z Twoim ¿¹daniem)
$CsvPath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data\HAA_IBM_WMQ_12_node_status.csv"

# Tworzymy listê na wyniki
$NodeResults = New-Object System.Collections.Generic.List[PSObject]

# Sprawdzamy, czy katalog docelowy istnieje, jeœli nie - tworzymy go
$Dir = Split-Path $CsvPath -Parent
if (!(Test-Path $Dir)) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    Write-Host "Utworzono katalog: $Dir" -ForegroundColor Yellow
}

foreach ($Server in $TargetServers) {
    try {
        # Próba po³¹czenia (State = Up)
        # ErrorAction Stop jest kluczowe, aby b³¹d po³¹czenia wyrzuci³ nas do bloku catch
        $result = Invoke-Command -ComputerName $Server -ErrorAction Stop -ScriptBlock {
            # Pobieramy IP (pomijamy loopback i pseudo-interfejsy)
            $IP = (Get-NetIPAddress -AddressFamily IPv4 | ?{$_.IPAddress -like "10.*"}).IPAddress
            
            # Zwracamy obiekt z nazw¹ i IP zdalnej maszyny
            [PSCustomObject]@{
                IP = $IP
                RealName = $env:COMPUTERNAME
            }
        }

        # Jeœli po³¹czenie siê uda, dodajemy wpis "Up"
        $NodeResults.Add([PSCustomObject]@{
            Name          = $result.RealName
            State         = "Up"
            NodeWeight    = "1"
            DynamicWeight = "1"
            IPAddresses   = $result.IP
        })
    }
    catch {
        # Jeœli po³¹czenie siê nie uda (b³¹d sieci/WinRM), dodajemy wpis "Down"
        $NodeResults.Add([PSCustomObject]@{
            Name          = $Server   # U¿ywamy nazwy z listy, bo nie uda³o siê po³¹czyæ
            State         = "Down"
            NodeWeight    = "1"
            DynamicWeight = "1"
            IPAddresses   = "Brak"
        })
        Write-Warning "Nie uda³o siê po³¹czyæ z serwerem: $Server"
    }
}

# Zapis do jednego pliku CSV we wskazanej lokalizacji
$NodeResults | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Delimiter ","

Write-Host "Plik zosta³ zapisany w: $CsvPath" -ForegroundColor Green


# Lista serwerów do sprawdzenia (wprowadŸ tutaj swoje nazwy)
$TargetServers = @("SRVMQ3", "SRVMQ4")

# Œcie¿ka zapisu pliku CSV (zgodnie z Twoim ¿¹daniem)
$CsvPath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data\HAA_IBM_WMQ_34_node_status.csv"

# Tworzymy listê na wyniki
$NodeResults = New-Object System.Collections.Generic.List[PSObject]

# Sprawdzamy, czy katalog docelowy istnieje, jeœli nie - tworzymy go
$Dir = Split-Path $CsvPath -Parent
if (!(Test-Path $Dir)) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    Write-Host "Utworzono katalog: $Dir" -ForegroundColor Yellow
}

foreach ($Server in $TargetServers) {
    try {
        # Próba po³¹czenia (State = Up)
        # ErrorAction Stop jest kluczowe, aby b³¹d po³¹czenia wyrzuci³ nas do bloku catch
        $result = Invoke-Command -ComputerName $Server -ErrorAction Stop -ScriptBlock {
            # Pobieramy IP (pomijamy loopback i pseudo-interfejsy)
            $IP = (Get-NetIPAddress -AddressFamily IPv4 | ?{$_.IPAddress -like "10.*"}).IPAddress
            
            # Zwracamy obiekt z nazw¹ i IP zdalnej maszyny
            [PSCustomObject]@{
                IP = $IP
                RealName = $env:COMPUTERNAME
            }
        }

        # Jeœli po³¹czenie siê uda, dodajemy wpis "Up"
        $NodeResults.Add([PSCustomObject]@{
            Name          = $result.RealName
            State         = "Up"
            NodeWeight    = "1"
            DynamicWeight = "1"
            IPAddresses   = $result.IP
        })
    }
    catch {
        # Jeœli po³¹czenie siê nie uda (b³¹d sieci/WinRM), dodajemy wpis "Down"
        $NodeResults.Add([PSCustomObject]@{
            Name          = $Server   # U¿ywamy nazwy z listy, bo nie uda³o siê po³¹czyæ
            State         = "Down"
            NodeWeight    = "1"
            DynamicWeight = "1"
            IPAddresses   = "Brak"
        })
        Write-Warning "Nie uda³o siê po³¹czyæ z serwerem: $Server"
    }
}

# Zapis do jednego pliku CSV we wskazanej lokalizacji
$NodeResults | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Delimiter ","

Write-Host "Plik zosta³ zapisany w: $CsvPath" -ForegroundColor Green





# Lista serwerów do sprawdzenia (wprowadŸ tutaj swoje nazwy)
$TargetServers = @("anowmq1", "anowmq2")

# Œcie¿ka zapisu pliku CSV (zgodnie z Twoim ¿¹daniem)
$CsvPath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data\FileTransfer_MQ_node_status.csv"

# Tworzymy listê na wyniki
$NodeResults = New-Object System.Collections.Generic.List[PSObject]

# Sprawdzamy, czy katalog docelowy istnieje, jeœli nie - tworzymy go
$Dir = Split-Path $CsvPath -Parent
if (!(Test-Path $Dir)) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    Write-Host "Utworzono katalog: $Dir" -ForegroundColor Yellow
}

foreach ($Server in $TargetServers) {
    try {
        # Próba po³¹czenia (State = Up)
        # ErrorAction Stop jest kluczowe, aby b³¹d po³¹czenia wyrzuci³ nas do bloku catch
        $result = Invoke-Command -ComputerName $Server -ErrorAction Stop -ScriptBlock {
            # Pobieramy IP (pomijamy loopback i pseudo-interfejsy)
            $IP = (Get-NetIPAddress -AddressFamily IPv4 | ?{$_.IPAddress -like "10.*"}).IPAddress
            
            # Zwracamy obiekt z nazw¹ i IP zdalnej maszyny
            [PSCustomObject]@{
                IP = $IP
                RealName = $env:COMPUTERNAME
            }
        }

        # Jeœli po³¹czenie siê uda, dodajemy wpis "Up"
        $NodeResults.Add([PSCustomObject]@{
            Name          = $result.RealName
            State         = "Up"
            NodeWeight    = "1"
            DynamicWeight = "1"
            IPAddresses   = $result.IP
        })
    }
    catch {
        # Jeœli po³¹czenie siê nie uda (b³¹d sieci/WinRM), dodajemy wpis "Down"
        $NodeResults.Add([PSCustomObject]@{
            Name          = $Server   # U¿ywamy nazwy z listy, bo nie uda³o siê po³¹czyæ
            State         = "Down"
            NodeWeight    = "1"
            DynamicWeight = "1"
            IPAddresses   = "Brak"
        })
        Write-Warning "Nie uda³o siê po³¹czyæ z serwerem: $Server"
    }
}

# Zapis do jednego pliku CSV we wskazanej lokalizacji
$NodeResults | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Delimiter ","

Write-Host "Plik zosta³ zapisany w: $CsvPath" -ForegroundColor Green
