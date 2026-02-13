#Requires -Version 5.1
# =============================================================================
# GetLogs.ps1
# Pobiera logi Windows Event Log z serwera i zapisuje do pliku
# =============================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$ServerName,

    [Parameter(Mandatory=$true)]
    [string]$LogName,

    [Parameter(Mandatory=$true)]
    [int]$MinutesBack,

    [string]$OutputPath = ""
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

try {
    $events = Get-WinEvent -ComputerName $ServerName -FilterHashtable @{
        LogName = $LogName
        StartTime = $startTime
    } -ErrorAction Stop | Select-Object @{
        Name='TimeCreated'
        Expression={$_.TimeCreated.ToString("yyyy-MM-ddTHH:mm:ss")}
    }, @{
        Name='LevelDisplayName'
        Expression={$_.LevelDisplayName}
    }, @{
        Name='Id'
        Expression={$_.Id}
    }, @{
        Name='ProviderName'
        Expression={$_.ProviderName}
    }, @{
        Name='Message'
        Expression={
            # Escape problematycznych znaków dla JSON
            $msg = $_.Message
            if ($msg) {
                $msg = $msg -replace '[\x00-\x1f]', ' '  # Usuń znaki kontrolne
                $msg = $msg -replace '\\', '\\\\'        # Escape backslash
                $msg = $msg.Trim()
            }
            $msg
        }
    }

    if ($events) {
        $jsonOutput = $events | ConvertTo-Json -Depth 3 -Compress

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
} catch [System.Exception] {
    if ($_.Exception.Message -like "*No events were found*") {
        "[]"
    } else {
        throw $_
    }
}
