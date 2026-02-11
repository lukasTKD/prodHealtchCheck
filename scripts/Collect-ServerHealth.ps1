#Requires -Version 5.1
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("DCI", "Ferryt", "MarketPlanet", "MQ", "FileTransfer", "Klastry")]
    [string]$Group,
    [int]$ThrottleLimit = 50
)

# ========== KONFIGURACJA ==========
$enableSCCM = 0   # 1 = wlaczone, 0 = wylaczone
# ==================================

$BasePath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
$ServerListPath = "$BasePath\serverList_$Group.txt"
$OutputPath = "$BasePath\data\serverHealth_$Group.json"

$ErrorActionPreference = "Continue"

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
        PendingUpdates = $(
            if ($using:enableSCCM -eq 1) {
                try {
                    $updates = Get-CimInstance -Namespace "root\ccm\clientsdk" -ClassName CCM_SoftwareUpdate -EA Stop
                    if ($updates) {
                        $available = @($updates | Where-Object { $_.EvaluationState -eq 1 })
                        @{
                            Enabled = $true
                            Count = $available.Count
                            Updates = @($available | Select-Object -First 10 | ForEach-Object {
                                @{ Name = $_.Name; ArticleID = $_.ArticleID }
                            })
                        }
                    } else {
                        @{ Enabled = $true; Count = 0; Updates = @() }
                    }
                } catch {
                    @{ Enabled = $true; Count = 0; Updates = @(); Error = $_.Exception.Message }
                }
            } else {
                @{ Enabled = $false }
            }
        )
    }
}

# Wczytaj serwery
if (-not (Test-Path $ServerListPath)) { Write-Error "Brak pliku: $ServerListPath"; exit 1 }
$servers = @(Get-Content $ServerListPath | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim() })
if ($servers.Count -eq 0) { Write-Error "Pusta lista dla grupy: $Group"; exit 1 }

Write-Host "[$Group] Zbieranie z $($servers.Count) serwerow..." -ForegroundColor Cyan
$startTime = Get-Date

# Wykonaj
$results = Invoke-Command -ComputerName $servers -ScriptBlock $ScriptBlock -ThrottleLimit $ThrottleLimit -ErrorAction SilentlyContinue -ErrorVariable errs

# Przetworzenie - uzyj ArrayList zeby wymusic tablice
$allResults = New-Object System.Collections.ArrayList
$ok = @()

foreach ($r in $results) {
    if ($r.ServerName) {
        $ok += $r.ServerName
        [void]$allResults.Add(@{
            ServerName = $r.ServerName; CollectedAt = $r.CollectedAt; CPU = $r.CPU; RAM = $r.RAM
            Disks = @($r.Disks); TopCPUServices = @($r.TopCPUServices); TopRAMServices = @($r.TopRAMServices)
            DServices = @($r.DServices); TrellixStatus = @($r.TrellixStatus); Firewall = $r.Firewall
            IIS = $r.IIS; PendingUpdates = $r.PendingUpdates
            Error = $null
        })
        Write-Host "  OK: $($r.ServerName)" -ForegroundColor Green
    }
}

foreach ($f in ($servers | Where-Object { $_ -notin $ok })) {
    [void]$allResults.Add(@{
        ServerName = $f; CollectedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); Error = "Timeout/Niedostepny"
        CPU = 0; RAM = @{}; Disks = @(); TopCPUServices = @(); TopRAMServices = @()
        DServices = @(); TrellixStatus = @(@{ Name = "Trellix"; State = "Unknown" }); Firewall = @{ Domain = $false; Private = $false; Public = $false }
        IIS = @{ Installed = $false }; PendingUpdates = @{ Enabled = $false }
    })
    Write-Host "  FAIL: $f" -ForegroundColor Red
}

$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

# Sortuj
$sortedList = New-Object System.Collections.ArrayList
$allResults | Sort-Object { $_.ServerName } | ForEach-Object { [void]$sortedList.Add($_) }

# Zbuduj JSON recznie zeby Servers ZAWSZE bylo tablica
$serversJson = ($sortedList | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }) -join ","

$json = @"
{"LastUpdate":"$((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))","CollectionDuration":$duration,"TotalServers":$($servers.Count),"SuccessCount":$($ok.Count),"FailedCount":$($servers.Count - $ok.Count),"Group":"$Group","Servers":[$serversJson]}
"@

$json | Out-File $OutputPath -Encoding UTF8 -Force

Write-Host "`n[$Group] Gotowe: ${duration}s (OK: $($ok.Count), FAIL: $($servers.Count - $ok.Count))" -ForegroundColor Green
