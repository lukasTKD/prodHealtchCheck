#Requires -Version 5.1
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("DCI", "Ferryt", "MarketPlanet", "MQ", "FileTransfer", "Klastry")]
    [string]$Group,
    [int]$ThrottleLimit = 100  # OPTYMALIZACJA: Zwiększony limit dla dużych środowisk
)

$BasePath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
$ServerListPath = "$BasePath\serverList_$Group.txt"
$OutputPath = "$BasePath\data\serverHealth_$Group.json"
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
    "$timestamp [$Group] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

$ScriptBlock = {
    # OPTYMALIZACJA: Użycie Get-CimInstance zamiast Get-WmiObject (szybsze, WS-Man)
    $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -EA SilentlyContinue
    $cpu = Get-CimInstance Win32_Processor -EA SilentlyContinue
    $os = Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue
    $procs = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -EA SilentlyContinue

    @{
        ServerName = $env:COMPUTERNAME
        CollectedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Disks = @($disks | ForEach-Object {
            @{
                Drive = $_.DeviceID
                TotalGB = [math]::Round($_.Size/1GB,1)
                FreeGB = [math]::Round($_.FreeSpace/1GB,1)
                PercentFree = [math]::Round(($_.FreeSpace/$_.Size)*100,0)
            }
        })
        CPU = [math]::Round(($cpu.LoadPercentage | Measure-Object -Average).Average, 0)
        RAM = $(
            $total = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
            $free = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
            @{ TotalGB = $total; FreeGB = $free; UsedGB = [math]::Round($total - $free, 1); PercentUsed = [math]::Round((($total - $free) / $total) * 100, 0) }
        )
        TopCPUServices = @($procs |
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

# Wczytaj serwery
if (-not (Test-Path $ServerListPath)) {
    Write-Log "BLAD: Brak pliku: $ServerListPath"
    exit 1
}

$servers = @(Get-Content $ServerListPath | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim() })
if ($servers.Count -eq 0) {
    Write-Log "BLAD: Pusta lista serwerow"
    exit 1
}

Write-Log "START zbierania z $($servers.Count) serwerow"
$startTime = Get-Date

# Wykonaj
$results = Invoke-Command -ComputerName $servers -ScriptBlock $ScriptBlock -ThrottleLimit $ThrottleLimit -ErrorAction SilentlyContinue -ErrorVariable errs

# Przetworzenie - OPTYMALIZACJA: List[object] zamiast ArrayList, buforowanie logów
$allResults = [System.Collections.Generic.List[object]]::new()
$ok = [System.Collections.Generic.List[string]]::new()
$logBuffer = [System.Collections.Generic.List[string]]::new()

foreach ($r in $results) {
    if ($r.ServerName) {
        $ok.Add($r.ServerName)
        $allResults.Add(@{
            ServerName = $r.ServerName
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
        $logBuffer.Add("OK: $($r.ServerName)")
    }
}

foreach ($f in ($servers | Where-Object { $_ -notin $ok })) {
    $allResults.Add(@{
        ServerName = $f
        CollectedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Error = "Timeout/Niedostepny"
        CPU = 0
        RAM = @{}
        Disks = @()
        TopCPUServices = @()
        TopRAMServices = @()
        DServices = @()
        TrellixStatus = @(@{ Name = "Trellix"; State = "Unknown" })
        Firewall = @{ Domain = $false; Private = $false; Public = $false }
        IIS = @{ Installed = $false }
    })
    $logBuffer.Add("FAIL: $f")
}

$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

# Sortuj - OPTYMALIZACJA: List[object] zamiast ArrayList
$sortedList = [System.Collections.Generic.List[object]]::new()
$allResults | Sort-Object { $_.ServerName } | ForEach-Object { $sortedList.Add($_) }

# Zbuduj JSON
$serversJson = ($sortedList | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }) -join ","

$json = @"
{"LastUpdate":"$((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))","CollectionDuration":$duration,"TotalServers":$($servers.Count),"SuccessCount":$($ok.Count),"FailedCount":$($servers.Count - $ok.Count),"Group":"$Group","Servers":[$serversJson]}
"@

$json | Out-File $OutputPath -Encoding UTF8 -Force

# OPTYMALIZACJA: Zapis wszystkich logów jednorazowo na końcu
$logBuffer.Add("KONIEC: ${duration}s (OK: $($ok.Count), FAIL: $($servers.Count - $ok.Count))")
$logBuffer | ForEach-Object { Write-Log $_ }
