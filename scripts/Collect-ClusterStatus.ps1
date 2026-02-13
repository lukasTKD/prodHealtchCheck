#Requires -Version 5.1
# =============================================================================
# Collect-ClusterStatus.ps1
# Zbiera status klastrow Windows - SZYBKA WERSJA
# Invoke-Command z lista serwerow = natywna rownoleglość
# =============================================================================

$ScriptPath = $PSScriptRoot
$ConfigFile = Join-Path (Split-Path $ScriptPath -Parent) "app-config.json"

if (Test-Path $ConfigFile) {
    $appConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $DataPath = $appConfig.paths.dataPath
    $LogsPath = $appConfig.paths.logsPath
    $ConfigPath = $appConfig.paths.configPath
} else {
    $BasePath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck"
    $DataPath = "$BasePath\data"
    $LogsPath = "$BasePath\logs"
    $ConfigPath = "$BasePath\config"
}

$OutputPath = "$DataPath\infra_ClustersWindows.json"
$LogPath = "$LogsPath\ServerHealthMonitor.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [CLUSTERS] $Message" | Out-File $LogPath -Append -Encoding UTF8
}

# Wczytaj konfiguracje
$ClustersConfigPath = "$ConfigPath\clusters.json"
if (-not (Test-Path $ClustersConfigPath)) {
    $ClustersConfigPath = "D:\PROD_REPO_DATA\IIS\Cluster\clusters.json"
}

if (-not (Test-Path $ClustersConfigPath)) {
    Write-Log "BLAD: Brak pliku clusters.json"
    @{ LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); TotalClusters = 0; Clusters = @() } | ConvertTo-Json -Depth 10 | Out-File $OutputPath -Encoding UTF8
    exit 1
}

$config = Get-Content $ClustersConfigPath -Raw | ConvertFrom-Json

# Zbuduj liste serwerow z typami
$clusterMap = @{}
foreach ($c in $config.clusters) {
    foreach ($srv in $c.servers) {
        $clusterMap[$srv] = $c.cluster_type
    }
}
$serverList = @($clusterMap.Keys)

Write-Log "START: $($serverList.Count) klastrow"
$startTime = Get-Date

# JEDNO Invoke-Command na wszystkie serwery - natywna rownoleglość
$rawResults = Invoke-Command -ComputerName $serverList -ErrorAction SilentlyContinue -ScriptBlock {
    $clusterName = (Get-Cluster -ErrorAction SilentlyContinue).Name
    if (-not $clusterName) { $clusterName = $env:COMPUTERNAME }

    $nodes = @(Get-ClusterNode -ErrorAction SilentlyContinue | ForEach-Object {
        $n = $_
        $ips = (Get-ClusterNetworkInterface -Node $n.Name -ErrorAction SilentlyContinue | ForEach-Object { $_.Address }) -join ", "
        @{
            Name          = $n.Name
            State         = $n.State.ToString()
            NodeWeight    = $n.NodeWeight
            DynamicWeight = $n.DynamicWeight
            IPAddresses   = if ($ips) { $ips } else { "N/A" }
        }
    })

    $roles = @(Get-ClusterGroup -ErrorAction SilentlyContinue | ForEach-Object {
        $r = $_
        $resources = Get-ClusterResource -ErrorAction SilentlyContinue | Where-Object { $_.OwnerGroup -eq $r.Name }
        $ips = ($resources | Where-Object { $_.ResourceType -eq "IP Address" } | ForEach-Object {
            try { (Get-ClusterParameter -InputObject $_ -Name Address -ErrorAction SilentlyContinue).Value } catch { }
        }) -join ", "
        @{
            Name        = $r.Name
            State       = $r.State.ToString()
            OwnerNode   = $r.OwnerNode.ToString()
            IPAddresses = $ips
        }
    })

    @{
        ClusterName = $clusterName
        Nodes       = $nodes
        Roles       = $roles
    }
}

# Przetwórz wyniki
$results = [System.Collections.ArrayList]::new()
foreach ($r in $rawResults) {
    $srv = $r.PSComputerName
    $type = $clusterMap[$srv]
    [void]$results.Add(@{
        Success     = $true
        ClusterName = $r.ClusterName
        FQDN        = $srv
        ClusterType = $type
        Status      = "Online"
        Nodes       = $r.Nodes
        Roles       = $r.Roles
        Error       = $null
    })
    Write-Log "OK: $($r.ClusterName) ($type)"
}

# Serwery ktore nie odpowiedzialy
$okServers = @($rawResults | ForEach-Object { $_.PSComputerName })
foreach ($srv in $serverList) {
    if ($srv -notin $okServers) {
        [void]$results.Add(@{
            Success     = $false
            ClusterName = $srv
            FQDN        = $srv
            ClusterType = $clusterMap[$srv]
            Status      = "Error"
            Nodes       = @()
            Roles       = @()
            Error       = "Timeout/Niedostepny"
        })
        Write-Log "FAIL: $srv"
    }
}

$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
$onlineCount = @($results | Where-Object { $_.Status -eq "Online" }).Count

@{
    LastUpdate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = $duration
    TotalClusters      = $results.Count
    OnlineCount        = $onlineCount
    FailedCount        = $results.Count - $onlineCount
    Clusters           = @($results)
} | ConvertTo-Json -Depth 10 | Out-File $OutputPath -Encoding UTF8 -Force

Write-Log "KONIEC: ${duration}s (OK: $onlineCount, FAIL: $($results.Count - $onlineCount))"
