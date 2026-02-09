#Requires -Version 5.1
param(
    [string]$ServerListPath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck\serverList.txt",
    [string]$OutputPath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data\serverHealth.json",
    [int]$ThrottleLimit = 50
)

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
        CPU = (Get-WmiObject Win32_Processor).LoadPercentage
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
            $svc = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\*" -EA SilentlyContinue | Where-Object { $_.ImagePath -like "D:\*" }
            if ($svc) {
                Get-Service -Name $svc.PSChildName -EA SilentlyContinue | ForEach-Object {
                    @{ Name = $_.Name; DisplayName = $_.DisplayName; State = $_.Status.ToString() }
                }
            }
        )
        TrellixStatus = $(
            $t = Get-Service -Name "mfefire","mfemms","mfevtp","masvc","macmnsvc" -EA SilentlyContinue | Select-Object -First 1
            if ($t) { $t.Status.ToString() } else { "NotFound" }
        )
        Firewall = @{
            Domain = (Get-NetFirewallProfile -Name Domain -EA SilentlyContinue).Enabled -eq $true
            Private = (Get-NetFirewallProfile -Name Private -EA SilentlyContinue).Enabled -eq $true
            Public = (Get-NetFirewallProfile -Name Public -EA SilentlyContinue).Enabled -eq $true
        }
    }
}

# Wczytaj serwery
if (-not (Test-Path $ServerListPath)) { Write-Error "Brak: $ServerListPath"; exit 1 }
$servers = @(Get-Content $ServerListPath | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim() })
if ($servers.Count -eq 0) { Write-Error "Pusta lista"; exit 1 }

Write-Host "Zbieranie z $($servers.Count) serwerow..." -ForegroundColor Cyan
$startTime = Get-Date

# Wykonaj
$results = Invoke-Command -ComputerName $servers -ScriptBlock $ScriptBlock -ThrottleLimit $ThrottleLimit -ErrorAction SilentlyContinue -ErrorVariable errs

# Przetworzenie
$allResults = @()
$ok = @()

foreach ($r in $results) {
    if ($r.ServerName) {
        $ok += $r.ServerName
        $allResults += @{
            ServerName = $r.ServerName; CollectedAt = $r.CollectedAt; CPU = $r.CPU; RAM = $r.RAM
            Disks = $r.Disks; TopCPUServices = $r.TopCPUServices; TopRAMServices = $r.TopRAMServices
            DServices = $r.DServices; TrellixStatus = $r.TrellixStatus; Firewall = $r.Firewall
            Error = $null
        }
        Write-Host "  OK: $($r.ServerName)" -ForegroundColor Green
    }
}

foreach ($f in ($servers | Where-Object { $_ -notin $ok })) {
    $allResults += @{
        ServerName = $f; CollectedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); Error = "Timeout/Niedostepny"
        CPU = 0; RAM = @{}; Disks = @(); TopCPUServices = @(); TopRAMServices = @()
        DServices = @(); TrellixStatus = "Unknown"; Firewall = @{ Domain = $false; Private = $false; Public = $false }
    }
    Write-Host "  FAIL: $f" -ForegroundColor Red
}

$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

@{
    LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $duration
    TotalServers = $servers.Count
    SuccessCount = $ok.Count
    FailedCount = ($servers.Count - $ok.Count)
    Servers = $allResults | Sort-Object { $_.ServerName }
} | ConvertTo-Json -Depth 10 -Compress | Out-File $OutputPath -Encoding UTF8 -Force

Write-Host "`nGotowe: ${duration}s (OK: $($ok.Count), FAIL: $($servers.Count - $ok.Count))" -ForegroundColor Green
