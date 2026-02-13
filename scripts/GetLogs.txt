#Requires -Version 5.1
# =============================================================================
# GetLogs.ps1
# Pobiera logi Windows Event Log z serwera i zapisuje do pliku
# Używa Invoke-Command (WinRM) zamiast Get-WinEvent -ComputerName (RPC)
# =============================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$ServerName,

    [Parameter(Mandatory=$true)]
    [string]$LogName,

    [Parameter(Mandatory=$true)]
    [int]$MinutesBack,

    [int]$MaxEvents = 1000
)

$ScriptPath = $PSScriptRoot
$ConfigFile = Join-Path (Split-Path $ScriptPath -Parent) "app-config.json"

# Wczytaj konfigurację
if (Test-Path $ConfigFile) {
    $appConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $EventLogsPath = $appConfig.paths.eventLogsPath
} else {
    $EventLogsPath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck\EventLogs"
}

# Upewnij się że katalog EventLogs istnieje
if (-not (Test-Path $EventLogsPath)) {
    New-Item -ItemType Directory -Path $EventLogsPath -Force | Out-Null
}

$startTime = (Get-Date).AddMinutes(-$MinutesBack)

# ScriptBlock wykonywany zdalnie przez Invoke-Command
$scriptBlock = {
    param($logName, $startTime, $maxEvents)

    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = $logName
            StartTime = $startTime
        } -MaxEvents $maxEvents -ErrorAction Stop

        @($events | ForEach-Object {
            @{
                TimeCreated    = $_.TimeCreated.ToString("yyyy-MM-ddTHH:mm:ss")
                LevelDisplayName = $_.LevelDisplayName
                Id             = $_.Id
                ProviderName   = $_.ProviderName
                Message        = ($_.Message -replace '[\x00-\x1f]', ' ').Trim()
            }
        })
    } catch {
        if ($_.Exception.Message -like "*No events were found*") {
            @()
        } else {
            throw $_
        }
    }
}

try {
    # Użyj Invoke-Command (WinRM) zamiast Get-WinEvent -ComputerName (RPC)
    $events = Invoke-Command -ComputerName $ServerName -ScriptBlock $scriptBlock `
        -ArgumentList $LogName, $startTime, $MaxEvents `
        -ErrorAction Stop

    if ($events -and $events.Count -gt 0) {
        # Konwertuj do JSON
        $jsonOutput = $events | ConvertTo-Json -Depth 3 -Compress

        # Dla pojedynczego eventu ConvertTo-Json nie zwraca tablicy
        if ($events.Count -eq 1) {
            $jsonOutput = "[$jsonOutput]"
        }

        # Zapisz do pliku w EventLogs
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $safeLogName = $LogName -replace '[/\\:\*\?"<>\|]', '_'
        $fileName = "${ServerName}_${safeLogName}_${timestamp}.json"
        $filePath = Join-Path $EventLogsPath $fileName

        # Zapisz z BOM-less UTF8
        [System.IO.File]::WriteAllText($filePath, $jsonOutput, [System.Text.UTF8Encoding]::new($false))

        # Zwróć JSON do stdout
        $jsonOutput
    } else {
        "[]"
    }
} catch {
    # Zwróć błąd jako JSON
    $errorJson = @{
        Error = $true
        Message = $_.Exception.Message
        Server = $ServerName
        LogName = $LogName
    } | ConvertTo-Json -Compress

    Write-Error $errorJson
    exit 1
}
