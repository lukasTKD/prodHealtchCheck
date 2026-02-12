#Requires -Version 5.1
param(
    [int]$ThrottleLimit = 50
)

$BasePath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
$ConfigPath = "$BasePath\serverList_DMZ.json"
$OutputPath = "$BasePath\data\serverHealth_DMZ.json"
$LogPath = "$BasePath\ServerHealthMonitor.log"
$LogMaxAgeHours = 48

$ErrorActionPreference = "Continue"

# Funkcja logowania z rollowaniem
function Write-Log {
    param([string]$Message)

    # Rollowanie logu co 48h
    if (Test-Path $LogPath) {
        $logFile = Get-Item $LogPath
        if ($logFile.LastWriteTime -lt (Get-Date).AddHours(-$LogMaxAgeHours)) {
            $archiveName = "$BasePath\ServerHealthMonitor_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            Move-Item $LogPath $archiveName -Force
        }
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [DMZ] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

# ScriptBlock wykonywany ZDALNIE na serwerach DMZ
$ScriptBlock = {
    @{
        ServerName = $env:COMPUTERNAME
        CollectedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Disks = @(Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
            @{
                Drive = $_.DeviceID
                TotalGB = [math]::Round($_.Size/1GB,1)
                FreeGB = [math]::Round($_.FreeSpace/1GB,1)
                PercentFree = [math]::Round(($_.FreeSpace/$_.Size)*100,0)
            }
        })
        CPU = [math]::Round(((Get-WmiObject Win32_Processor).LoadPercentage | Measure-Object -Average).Average, 0)
        RAM = $(
            $os = Get-WmiObject Win32_OperatingSystem
            $total = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
            $free = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
            @{ TotalGB = $total; FreeGB = $free; UsedGB = [math]::Round($total - $free, 1); PercentUsed = [math]::Round((($total - $free) / $total) * 100, 0) }
        )
        TopCPUServices = @(Get-WmiObject Win32_PerfFormattedData_PerfProc_Process |
            Where-Object { $_.Name -ne '_Total' -and $_.Name -ne 'Idle' } |
            Sort-Object PercentProcessorTime -Descending | Select-Object -First 3 | ForEach-Object {
            @{ Name = $_.Name; CPUPercent = $_.PercentProcessorTime }
        })
        TopRAMServices = @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 3 | ForEach-Object {
            @{ Name = $_.Name; MemoryMB = [math]::Round($_.WorkingSet64/1MB,0) }
        })
        DServices = @(
            Get-CimInstance Win32_Service -EA SilentlyContinue | Where-Object { $_.PathName -match '[DE]:[/\\]' } | ForEach-Object {
                @{ Name = $_.Name; DisplayName = $_.DisplayName; State = $_.State }
            }
        )
        TrellixStatus = @(
            $t = Get-Service -DisplayName "Trellix Endpoint*" -EA SilentlyContinue
            if ($t) {
                $t | ForEach-Object { @{ Name = $_.DisplayName; State = $_.Status.ToString() } }
            } else { @{ Name = "Trellix"; State = "NotFound" } }
        )
        Firewall = @{
            Domain = (Get-NetFirewallProfile -Name Domain -EA SilentlyContinue).Enabled -eq $true
            Private = (Get-NetFirewallProfile -Name Private -EA SilentlyContinue).Enabled -eq $true
            Public = (Get-NetFirewallProfile -Name Public -EA SilentlyContinue).Enabled -eq $true
        }
        IIS = $(
            $iisService = Get-Service -Name W3SVC -EA SilentlyContinue
            if ($iisService) {
                try {
                    Import-Module WebAdministration -EA Stop
                    @{
                        Installed = $true
                        ServiceState = $iisService.Status.ToString()
                        AppPools = @(Get-ChildItem IIS:\AppPools -EA SilentlyContinue | ForEach-Object {
                            @{ Name = $_.Name; State = $_.State }
                        })
                        Sites = @(Get-ChildItem IIS:\Sites -EA SilentlyContinue | ForEach-Object {
                            @{ Name = $_.Name; State = $_.State; Bindings = ($_.Bindings.Collection | ForEach-Object { $_.bindingInformation }) -join ", " }
                        })
                    }
                } catch {
                    @{ Installed = $true; ServiceState = $iisService.Status.ToString(); AppPools = @(); Sites = @(); Error = "Modul WebAdministration niedostepny" }
                }
            } else {
                @{ Installed = $false }
            }
        )
    }
}

# Wczytaj konfiguracje DMZ
if (-not (Test-Path $ConfigPath)) {
    Write-Log "BLAD: Brak pliku konfiguracji: $ConfigPath"
    exit 1
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not $config.groups -or $config.groups.Count -eq 0) {
    Write-Log "BLAD: Brak zdefiniowanych grup w konfiguracji"
    exit 1
}

Write-Log "START zbierania danych DMZ"

$startTime = Get-Date
$allResults = New-Object System.Collections.ArrayList
$totalServers = 0
$totalOk = 0
$totalFail = 0

# Opcje sesji SSL dla DMZ
$sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck

# Przetwarzaj kazda grupe
foreach ($group in $config.groups) {
    $groupName = $group.name
    $username = $group.login
    $password = $group.password
    $servers = @($group.servers)

    if ($servers.Count -eq 0) {
        Write-Log "[$groupName] Brak serwerow - pomijam"
        continue
    }

    Write-Log "[$groupName] Przetwarzanie $($servers.Count) serwerow..."

    # Utworz credential
    try {
        $secret = ConvertTo-SecureString -String $password
        $cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $username, $secret
    } catch {
        Write-Log "[$groupName] BLAD: Nie mozna odszyfrowac hasla"
        foreach ($server in $servers) {
            [void]$allResults.Add(@{
                ServerName = $server
                DMZGroup = $groupName
                CollectedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                Error = "Blad deszyfrowania hasla"
                CPU = 0; RAM = @{}; Disks = @(); TopCPUServices = @(); TopRAMServices = @()
                DServices = @(); TrellixStatus = @(@{ Name = "Trellix"; State = "Unknown" })
                Firewall = @{ Domain = $false; Private = $false; Public = $false }
                IIS = @{ Installed = $false }
            })
            $totalFail++
        }
        $totalServers += $servers.Count
        continue
    }

    # Batch Invoke-Command dla calej grupy
    $groupOk = @()

    $results = Invoke-Command -ComputerName $servers `
        -UseSSL `
        -Authentication Negotiate `
        -SessionOption $sessionOption `
        -Credential $cred `
        -ScriptBlock $ScriptBlock `
        -ThrottleLimit $ThrottleLimit `
        -ErrorAction SilentlyContinue `
        -ErrorVariable groupErrors

    foreach ($r in $results) {
        if ($r.ServerName) {
            $groupOk += $r.PSComputerName
            [void]$allResults.Add(@{
                ServerName = $r.ServerName
                DMZGroup = $groupName
                CollectedAt = $r.CollectedAt
                CPU = $r.CPU
                RAM = $r.RAM
                Disks = @($r.Disks)
                TopCPUServices = @($r.TopCPUServices)
                TopRAMServices = @($r.TopRAMServices)
                DServices = @($r.DServices)
                TrellixStatus = @($r.TrellixStatus)
                Firewall = $r.Firewall
                IIS = $r.IIS
                Error = $null
            })
            Write-Log "[$groupName] OK: $($r.ServerName)"
            $totalOk++
        }
    }

    # Dodaj nieudane serwery
    foreach ($server in $servers) {
        if ($server -notin $groupOk) {
            $errMsg = "Timeout/Niedostepny"
            $serverErr = $groupErrors | Where-Object { $_.TargetObject -eq $server } | Select-Object -First 1
            if ($serverErr) { $errMsg = $serverErr.Exception.Message }

            [void]$allResults.Add(@{
                ServerName = $server
                DMZGroup = $groupName
                CollectedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                Error = $errMsg
                CPU = 0; RAM = @{}; Disks = @(); TopCPUServices = @(); TopRAMServices = @()
                DServices = @(); TrellixStatus = @(@{ Name = "Trellix"; State = "Unknown" })
                Firewall = @{ Domain = $false; Private = $false; Public = $false }
                IIS = @{ Installed = $false }
            })
            Write-Log "[$groupName] FAIL: $server"
            $totalFail++
        }
    }

    $totalServers += $servers.Count
}

$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

# Sortuj wyniki
$sortedList = New-Object System.Collections.ArrayList
$allResults | Sort-Object { $_.DMZGroup }, { $_.ServerName } | ForEach-Object { [void]$sortedList.Add($_) }

# Zbuduj JSON
$serversJson = ($sortedList | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }) -join ","

$json = @"
{"LastUpdate":"$((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))","CollectionDuration":$duration,"TotalServers":$totalServers,"SuccessCount":$totalOk,"FailedCount":$totalFail,"Group":"DMZ","Servers":[$serversJson]}
"@

# Upewnij sie, ze folder data istnieje
$dataFolder = Split-Path $OutputPath -Parent
if (-not (Test-Path $dataFolder)) {
    New-Item -ItemType Directory -Path $dataFolder -Force | Out-Null
}

$json | Out-File $OutputPath -Encoding UTF8 -Force

Write-Log "KONIEC: ${duration}s (OK: $totalOk, FAIL: $totalFail, TOTAL: $totalServers)"
