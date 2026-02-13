#Requires -Version 5.1
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("DCI", "Ferryt", "MarketPlanet", "MQ", "FileTransfer", "Klastry")]
    [string]$Group,
    [int]$ThrottleLimit = 50
)

$ScriptPath = $PSScriptRoot
$ConfigFile = Join-Path (Split-Path $ScriptPath -Parent) "app-config.json"

# Wczytaj konfigurację
if (Test-Path $ConfigFile) {
    $appConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $BasePath = $appConfig.paths.basePath
    $DataPath = $appConfig.paths.dataPath
    $LogsPath = $appConfig.paths.logsPath
    $AppConfigPath = $appConfig.paths.configPath
} else {
    $BasePath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
    $DataPath = "$BasePath\data"
    $LogsPath = "$BasePath\logs"
    $AppConfigPath = "$BasePath\config"
}

# Upewnij się że katalogi istnieją
@($DataPath, $LogsPath) | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }
}

# Znajdź plik z listą serwerów w różnych lokalizacjach
$possiblePaths = @(
    "$AppConfigPath\serverList_$Group.txt",
    "$BasePath\serverList_$Group.txt"
)
$ServerListPath = $null
foreach ($path in $possiblePaths) {
    if (Test-Path $path) {
        $ServerListPath = $path
        break
    }
}
if (-not $ServerListPath) {
    $ServerListPath = $possiblePaths[0]  # Domyślna ścieżka dla komunikatu o błędzie
}

$OutputPath = "$DataPath\serverHealth_$Group.json"
$LogPath = "$LogsPath\ServerHealthMonitor.log"
$LogMaxAgeHours = 48

$ErrorActionPreference = "Continue"

# Funkcja logowania z rollowaniem
function Write-Log {
    param([string]$Message)

    # Rollowanie logu co 48h
    if (Test-Path $LogPath) {
        $logFile = Get-Item $LogPath
        if ($logFile.LastWriteTime -lt (Get-Date).AddHours(-$LogMaxAgeHours)) {
            $archiveName = "$LogsPath\ServerHealthMonitor_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            Move-Item $LogPath $archiveName -Force
        }
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [$Group] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

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

# Przetworzenie
$allResults = New-Object System.Collections.ArrayList
$ok = @()

foreach ($r in $results) {
    if ($r.ServerName) {
        $ok += $r.ServerName
        [void]$allResults.Add(@{
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
        Write-Log "OK: $($r.ServerName)"
    }
}

foreach ($f in ($servers | Where-Object { $_ -notin $ok })) {
    [void]$allResults.Add(@{
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
    Write-Log "FAIL: $f"
}

$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

# Sortuj
$sortedList = New-Object System.Collections.ArrayList
$allResults | Sort-Object { $_.ServerName } | ForEach-Object { [void]$sortedList.Add($_) }

# Zbuduj JSON
$serversJson = ($sortedList | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }) -join ","

$json = @"
{"LastUpdate":"$((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))","CollectionDuration":$duration,"TotalServers":$($servers.Count),"SuccessCount":$($ok.Count),"FailedCount":$($servers.Count - $ok.Count),"Group":"$Group","Servers":[$serversJson]}
"@

$json | Out-File $OutputPath -Encoding UTF8 -Force

Write-Log "KONIEC: ${duration}s (OK: $($ok.Count), FAIL: $($servers.Count - $ok.Count))"
