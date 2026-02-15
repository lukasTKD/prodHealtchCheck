#Requires -Version 5.1
# =============================================================================
# Collect-InfraData.ps1
# Scalony skrypt: instancje SQL + udzialy sieciowe FileShare
# Wykonanie zdalne (Invoke-Command) rownolegle - wzor z Collect-ServerHealth.ps1
# =============================================================================
param(
    [int]$ThrottleLimit = 50
)

$ScriptPath = $PSScriptRoot
$ConfigFile = Join-Path (Split-Path $ScriptPath -Parent) "app-config.json"

if (Test-Path $ConfigFile) {
    $appConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $DataPath = $appConfig.paths.dataPath
    $LogsPath = $appConfig.paths.logsPath
    $ConfigPath = $appConfig.paths.configPath
    $OutputSQL = Join-Path $DataPath $appConfig.outputs.infra.instancjeSQL
    $OutputShares = Join-Path $DataPath $appConfig.outputs.infra.udzialySieciowe
} else {
    $BasePath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
    $DataPath = "$BasePath\data"
    $LogsPath = "$BasePath\logs"
    $ConfigPath = "$BasePath\config"
    $OutputSQL = "$DataPath\infra_InstancjeSQL.json"
    $OutputShares = "$DataPath\infra_UdzialySieciowe.json"
}

@($DataPath, $LogsPath) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

$LogPath = "$LogsPath\ServerHealthMonitor.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [INFRA] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

Write-Log "=== START Collect-InfraData ==="
$startTime = Get-Date

# Wczytaj konfiguracje klastrow
$ClustersConfigPath = "$ConfigPath\clusters.json"
if (-not (Test-Path $ClustersConfigPath)) {
    Write-Log "BLAD: Brak pliku clusters.json"
    @{
        LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CollectionDuration = "0"
        TotalInstances = 0
        Instances = @()
    } | ConvertTo-Json -Depth 10 | Out-File $OutputSQL -Encoding UTF8
    @{
        LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CollectionDuration = "0"
        TotalServers = 0
        FileServers = @()
    } | ConvertTo-Json -Depth 10 | Out-File $OutputShares -Encoding UTF8
    exit 1
}

$clustersData = Get-Content $ClustersConfigPath -Raw | ConvertFrom-Json

# Wyodrebnij serwery SQL i FileShare
$sqlServers = @($clustersData.clusters | Where-Object { $_.cluster_type -eq "SQL" } | ForEach-Object { $_.servers } | ForEach-Object { $_ } | Select-Object -Unique)
$fileShareServers = @($clustersData.clusters | Where-Object { $_.cluster_type -eq "FileShare" } | ForEach-Object { $_.servers } | ForEach-Object { $_ } | Select-Object -Unique)

Write-Log "Serwery SQL ($($sqlServers.Count)): $($sqlServers -join ', ')"
Write-Log "Serwery FileShare ($($fileShareServers.Count)): $($fileShareServers -join ', ')"

# ============================================================================
# CZESC 1: Instancje SQL
# ============================================================================
$sqlInstances = [System.Collections.ArrayList]::new()

if ($sqlServers.Count -gt 0) {
    # ScriptBlock dla SQL - wykonuje zapytanie SQL lokalnie na serwerze
    $SqlScriptBlock = {
        $result = @{
            ServerName = $env:COMPUTERNAME
            SQLVersion = "N/A"
            DatabaseCount = 0
            TotalSizeMB = 0
            Error = $null
            Databases = @()
        }

        try {
            # Znajdz instancje SQL na serwerze
            $sqlServices = Get-Service -Name "MSSQL*" -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Running" }

            if ($sqlServices) {
                # Ustal nazwe instancji
                $instanceName = $env:COMPUTERNAME
                foreach ($svc in $sqlServices) {
                    if ($svc.Name -eq "MSSQLSERVER") {
                        $instanceName = $env:COMPUTERNAME
                        break
                    } elseif ($svc.Name -match "MSSQL\$(.+)") {
                        $instanceName = "$env:COMPUTERNAME\$($Matches[1])"
                        break
                    }
                }

                # Wykonaj zapytanie SQL
                $query = @"
SELECT
    d.name AS DatabaseName,
    d.compatibility_level AS CompatibilityLevel,
    CONVERT(VARCHAR(20), SERVERPROPERTY('ProductVersion')) AS SQLServerVersion,
    CAST(SUM(CASE WHEN mf.type = 0 THEN mf.size * 8.0 / 1024 ELSE 0 END) AS DECIMAL(10,2)) AS DataFileSizeMB,
    CAST(SUM(CASE WHEN mf.type = 1 THEN mf.size * 8.0 / 1024 ELSE 0 END) AS DECIMAL(10,2)) AS LogFileSizeMB,
    CAST(SUM(mf.size * 8.0 / 1024) AS DECIMAL(10,2)) AS TotalSizeMB
FROM sys.databases d
JOIN sys.master_files mf ON d.database_id = mf.database_id
GROUP BY d.name, d.compatibility_level
ORDER BY d.name;
"@

                # Uzyj SqlClient zamiast Invoke-Sqlcmd (nie wymaga modulu)
                $connectionString = "Server=$instanceName;Database=master;Integrated Security=True;Connection Timeout=10"
                $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
                $connection.Open()

                $command = $connection.CreateCommand()
                $command.CommandText = $query
                $command.CommandTimeout = 30

                $reader = $command.ExecuteReader()

                $databases = @()
                $totalSize = 0
                $sqlVersion = "N/A"

                while ($reader.Read()) {
                    if ($sqlVersion -eq "N/A" -and $reader["SQLServerVersion"]) {
                        $sqlVersion = "SQL Server " + $reader["SQLServerVersion"].ToString()
                    }
                    $dbSize = [math]::Round([double]$reader["TotalSizeMB"], 0)
                    $databases += @{
                        DatabaseName = $reader["DatabaseName"].ToString()
                        CompatibilityLevel = [int]$reader["CompatibilityLevel"]
                        DataFileSizeMB = [math]::Round([double]$reader["DataFileSizeMB"], 0)
                        LogFileSizeMB = [math]::Round([double]$reader["LogFileSizeMB"], 0)
                        TotalSizeMB = $dbSize
                    }
                    $totalSize += $dbSize
                }

                $reader.Close()
                $connection.Close()

                $result.SQLVersion = $sqlVersion
                $result.DatabaseCount = $databases.Count
                $result.TotalSizeMB = [math]::Round($totalSize, 0)
                $result.Databases = $databases
            } else {
                $result.Error = "Brak uruchomionej instancji SQL"
            }
        } catch {
            $result.Error = $_.Exception.Message
        }

        $result
    }

    # Wykonaj rownolegle
    $sqlResults = Invoke-Command -ComputerName $sqlServers -ScriptBlock $SqlScriptBlock -ThrottleLimit $ThrottleLimit -ErrorAction SilentlyContinue -ErrorVariable sqlErrs

    $okSqlServers = @()

    foreach ($r in $sqlResults) {
        if ($r.ServerName) {
            $okSqlServers += $r.PSComputerName

            [void]$sqlInstances.Add(@{
                ServerName = $r.ServerName
                SQLVersion = $r.SQLVersion
                DatabaseCount = $r.DatabaseCount
                TotalSizeMB = $r.TotalSizeMB
                Error = $r.Error
                Databases = @($r.Databases)
            })

            if ($r.Error) {
                Write-Log "SQL FAIL: $($r.ServerName) - $($r.Error)"
            } else {
                Write-Log "SQL OK: $($r.ServerName) ($($r.DatabaseCount) baz, $([math]::Round($r.TotalSizeMB/1024, 1)) GB)"
            }
        }
    }

    # Serwery ktore nie odpowiedzialy
    foreach ($srv in $sqlServers) {
        if ($srv -notin $okSqlServers) {
            [void]$sqlInstances.Add(@{
                ServerName = $srv
                SQLVersion = "N/A"
                DatabaseCount = 0
                TotalSizeMB = 0
                Error = "Niedostepny"
                Databases = @()
            })
            Write-Log "SQL FAIL: $srv - Niedostepny"
        }
    }
}

# ============================================================================
# CZESC 2: Udzialy sieciowe FileShare
# ============================================================================
$fileServers = [System.Collections.ArrayList]::new()

if ($fileShareServers.Count -gt 0) {
    # ScriptBlock dla FileShare
    $SharesScriptBlock = {
        $result = @{
            ServerName = $env:COMPUTERNAME
            ShareCount = 0
            Error = $null
            Shares = @()
        }

        try {
            $shares = Get-SmbShare -ErrorAction Stop |
                      Where-Object { $_.Path -and $_.ShareType -ne 'Special' -and $_.Name -notmatch '^\$' }

            $shareList = @()
            foreach ($share in $shares) {
                $shareList += @{
                    ShareName = $share.Name
                    SharePath = $share.Path
                    ShareState = if ($share.ShareState) { $share.ShareState.ToString() } else { "Online" }
                }
            }

            $result.ShareCount = $shareList.Count
            $result.Shares = $shareList
        } catch {
            $result.Error = $_.Exception.Message
        }

        $result
    }

    # Wykonaj rownolegle
    $shareResults = Invoke-Command -ComputerName $fileShareServers -ScriptBlock $SharesScriptBlock -ThrottleLimit $ThrottleLimit -ErrorAction SilentlyContinue -ErrorVariable shareErrs

    $okShareServers = @()

    foreach ($r in $shareResults) {
        if ($r.ServerName) {
            $okShareServers += $r.PSComputerName

            [void]$fileServers.Add(@{
                ServerName = $r.ServerName
                ShareCount = $r.ShareCount
                Error = $r.Error
                Shares = @($r.Shares)
            })

            if ($r.Error) {
                Write-Log "SHARES FAIL: $($r.ServerName) - $($r.Error)"
            } else {
                Write-Log "SHARES OK: $($r.ServerName) ($($r.ShareCount) udzialow)"
            }
        }
    }

    # Serwery ktore nie odpowiedzialy
    foreach ($srv in $fileShareServers) {
        if ($srv -notin $okShareServers) {
            [void]$fileServers.Add(@{
                ServerName = $srv
                ShareCount = 0
                Error = "Niedostepny"
                Shares = @()
            })
            Write-Log "SHARES FAIL: $srv - Niedostepny"
        }
    }
}

$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

# === ZAPIS 1: Instancje SQL ===
@{
    LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $duration.ToString()
    TotalInstances = $sqlInstances.Count
    Instances = @($sqlInstances)
} | ConvertTo-Json -Depth 10 | Out-File $OutputSQL -Encoding UTF8 -Force

Write-Log "Zapisano: $OutputSQL"

# === ZAPIS 2: Udzialy sieciowe ===
@{
    LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $duration.ToString()
    TotalServers = $fileServers.Count
    FileServers = @($fileServers)
} | ConvertTo-Json -Depth 10 | Out-File $OutputShares -Encoding UTF8 -Force

Write-Log "Zapisano: $OutputShares"
Write-Log "=== KONIEC Collect-InfraData (${duration}s) ==="
