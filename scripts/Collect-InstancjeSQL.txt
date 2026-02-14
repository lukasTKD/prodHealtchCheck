#Requires -Version 5.1
# =============================================================================
# Collect-InstancjeSQL.ps1
# Pobiera informacje o bazach danych SQL z serwerow zdefiniowanych w clusters.json
# =============================================================================

$ScriptPath = $PSScriptRoot
$ConfigFile = Join-Path (Split-Path $ScriptPath -Parent) "app-config.json"

if (Test-Path $ConfigFile) {
    $appConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $DataPath = $appConfig.paths.dataPath
    $LogsPath = $appConfig.paths.logsPath
    $ConfigPath = $appConfig.paths.configPath
    # Plik wyjsciowy z konfiguracji
    $OutputFile = Join-Path $DataPath $appConfig.outputs.infra.instancjeSQL
} else {
    $BasePath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
    $DataPath = "$BasePath\data"
    $LogsPath = "$BasePath\logs"
    $ConfigPath = "$BasePath\config"
    $OutputFile = "$DataPath\infra_InstancjeSQL.json"
}
$LogPath = "$LogsPath\ServerHealthMonitor.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [SQL] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

Write-Log "=== START Collect-InstancjeSQL ==="
$startTime = Get-Date

# Wczytaj konfiguracje
$ClustersConfigPath = "$ConfigPath\clusters.json"
if (-not (Test-Path $ClustersConfigPath)) {
    Write-Log "BLAD: Brak pliku clusters.json"
    @{
        LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CollectionDuration = "0"
        TotalInstances = 0
        Instances = @()
    } | ConvertTo-Json -Depth 10 | Out-File $OutputFile -Encoding UTF8
    exit 1
}

$clustersData = Get-Content $ClustersConfigPath -Raw | ConvertFrom-Json
$sqlServers = @($clustersData.clusters | Where-Object { $_.cluster_type -eq "SQL" } | ForEach-Object { $_.servers } | ForEach-Object { $_ })

if ($sqlServers.Count -eq 0) {
    Write-Log "Brak serwerow SQL w konfiguracji"
    @{
        LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CollectionDuration = "0"
        TotalInstances = 0
        Instances = @()
    } | ConvertTo-Json -Depth 10 | Out-File $OutputFile -Encoding UTF8
    exit 0
}

Write-Log "Serwery SQL: $($sqlServers -join ', ')"

# Zapytanie SQL
$query = @"
SELECT
    d.name AS DatabaseName,
    d.compatibility_level AS CompatibilityLevel,
    CONVERT(VARCHAR(20), SERVERPROPERTY('ProductVersion')) AS SQLServerVersion,
    CAST(SUM(CASE WHEN mf.type = 0 THEN mf.size * 8.0 / 1024 ELSE 0 END) AS DECIMAL(10,2)) AS DataFileSizeMB,
    CAST(SUM(CASE WHEN mf.type = 1 THEN mf.size * 8.0 / 1024 ELSE 0 END) AS DECIMAL(10,2)) AS LogFileSizeMB,
    CAST(SUM(mf.size * 8.0 / 1024) AS DECIMAL(10,2)) AS TotalSizeMB
FROM
    sys.databases d
JOIN
    sys.master_files mf ON d.database_id = mf.database_id
GROUP BY
    d.name, d.compatibility_level
ORDER BY
    d.name;
"@

$instances = [System.Collections.ArrayList]::new()

foreach ($server in $sqlServers) {
    Write-Log "Pobieranie z: $server"
    try {
        $dbInfo = Invoke-Sqlcmd -ServerInstance $server -Query $query -ErrorAction Stop

        $databases = @()
        $totalSize = 0
        $sqlVersion = "N/A"

        foreach ($db in $dbInfo) {
            if ($sqlVersion -eq "N/A" -and $db.SQLServerVersion) {
                $sqlVersion = "SQL Server " + $db.SQLServerVersion
            }
            $databases += @{
                DatabaseName = $db.DatabaseName
                CompatibilityLevel = [int]$db.CompatibilityLevel
                DataFileSizeMB = [math]::Round($db.DataFileSizeMB, 0)
                LogFileSizeMB = [math]::Round($db.LogFileSizeMB, 0)
                TotalSizeMB = [math]::Round($db.TotalSizeMB, 0)
            }
            $totalSize += $db.TotalSizeMB
        }

        [void]$instances.Add(@{
            ServerName = $server
            SQLVersion = $sqlVersion
            DatabaseCount = $databases.Count
            TotalSizeMB = [math]::Round($totalSize, 0)
            Error = $null
            Databases = $databases
        })

        Write-Log "OK: $server ($($databases.Count) baz, $([math]::Round($totalSize/1024, 1)) GB)"
    }
    catch {
        [void]$instances.Add(@{
            ServerName = $server
            SQLVersion = "N/A"
            DatabaseCount = 0
            TotalSizeMB = 0
            Error = $_.Exception.Message
            Databases = @()
        })
        Write-Log "FAIL: $server - $($_.Exception.Message)"
    }
}

$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

@{
    LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $duration.ToString()
    TotalInstances = $instances.Count
    Instances = @($instances)
} | ConvertTo-Json -Depth 10 | Out-File $OutputFile -Encoding UTF8 -Force

Write-Log "=== KONIEC Collect-InstancjeSQL (${duration}s) ==="
