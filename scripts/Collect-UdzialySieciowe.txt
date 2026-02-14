#Requires -Version 5.1
# =============================================================================
# Collect-UdzialySieciowe.ps1
# Pobiera udzialy sieciowe z serwerow FileShare zdefiniowanych w clusters.json
# =============================================================================

$ScriptPath = $PSScriptRoot
$ConfigFile = Join-Path (Split-Path $ScriptPath -Parent) "app-config.json"

if (Test-Path $ConfigFile) {
    $appConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $DataPath = $appConfig.paths.dataPath
    $LogsPath = $appConfig.paths.logsPath
    $ConfigPath = $appConfig.paths.configPath
    # Plik wyjsciowy z konfiguracji
    $OutputFile = Join-Path $DataPath $appConfig.outputs.infra.udzialySieciowe
} else {
    $BasePath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
    $DataPath = "$BasePath\data"
    $LogsPath = "$BasePath\logs"
    $ConfigPath = "$BasePath\config"
    $OutputFile = "$DataPath\infra_UdzialySieciowe.json"
}
$LogPath = "$LogsPath\ServerHealthMonitor.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [SHARES] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

Write-Log "=== START Collect-UdzialySieciowe ==="
$startTime = Get-Date

# Wczytaj konfiguracje
$ClustersConfigPath = "$ConfigPath\clusters.json"
if (-not (Test-Path $ClustersConfigPath)) {
    Write-Log "BLAD: Brak pliku clusters.json"
    @{
        LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CollectionDuration = "0"
        TotalServers = 0
        FileServers = @()
    } | ConvertTo-Json -Depth 10 | Out-File $OutputFile -Encoding UTF8
    exit 1
}

$clustersData = Get-Content $ClustersConfigPath -Raw | ConvertFrom-Json
$fileShareServers = @($clustersData.clusters | Where-Object { $_.cluster_type -eq "FileShare" } | ForEach-Object { $_.servers } | ForEach-Object { $_ })

if ($fileShareServers.Count -eq 0) {
    Write-Log "Brak serwerow FileShare w konfiguracji"
    @{
        LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CollectionDuration = "0"
        TotalServers = 0
        FileServers = @()
    } | ConvertTo-Json -Depth 10 | Out-File $OutputFile -Encoding UTF8
    exit 0
}

Write-Log "Serwery FileShare: $($fileShareServers -join ', ')"

$fileServers = [System.Collections.ArrayList]::new()

foreach ($server in $fileShareServers) {
    Write-Log "Pobieranie z: $server"
    try {
        $shares = Get-SmbShare -CimSession $server -ErrorAction Stop |
                  Where-Object { $_.Path -and $_.ShareType -ne 'Special' -and $_.Name -notmatch '^\$' }

        $shareList = @()
        foreach ($share in $shares) {
            $shareList += @{
                ShareName = $share.Name
                SharePath = $share.Path
                ShareState = if ($share.ShareState) { $share.ShareState.ToString() } else { "Online" }
            }
        }

        [void]$fileServers.Add(@{
            ServerName = $server
            ShareCount = $shareList.Count
            Error = $null
            Shares = $shareList
        })

        Write-Log "OK: $server ($($shareList.Count) udzialow)"
    }
    catch {
        [void]$fileServers.Add(@{
            ServerName = $server
            ShareCount = 0
            Error = $_.Exception.Message
            Shares = @()
        })
        Write-Log "FAIL: $server - $($_.Exception.Message)"
    }
}

$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

@{
    LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $duration.ToString()
    TotalServers = $fileServers.Count
    FileServers = @($fileServers)
} | ConvertTo-Json -Depth 10 | Out-File $OutputFile -Encoding UTF8 -Force

Write-Log "=== KONIEC Collect-UdzialySieciowe (${duration}s) ==="
