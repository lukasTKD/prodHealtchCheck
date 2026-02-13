# Collect-ClusterStatus.ps1
# Zbiera status klastrow Windows (SQL, FileShare) oraz grup MQ
# Wzor: cluster.ps1 / Get-ClusterStatusReport.ps1 (uzywa -Cluster zamiast Invoke-Command)

# --- SCIEZKI ---
$ScriptDir  = Split-Path $PSScriptRoot -Parent
$appConfig  = Get-Content "$ScriptDir\app-config.json" | ConvertFrom-Json
$DataPath   = $appConfig.paths.dataPath
$ConfigPath = $appConfig.paths.configPath
$LogsPath   = $appConfig.paths.logsPath

if (!(Test-Path $DataPath))  { New-Item -ItemType Directory -Path $DataPath  -Force | Out-Null }
if (!(Test-Path $LogsPath))  { New-Item -ItemType Directory -Path $LogsPath  -Force | Out-Null }

$OutputFile = "$DataPath\infra_ClustersWindows.json"
$LogFile    = "$LogsPath\ServerHealthMonitor.log"

function Log($msg) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [CLUSTERS] $msg" | Out-File $LogFile -Append -Encoding UTF8 }

Log "START"

# --- KONFIGURACJA ---
$clustersJson = Get-Content "$ConfigPath\clusters.json" | ConvertFrom-Json
$mqJson       = $null
$mqFile       = "$ConfigPath\mq_servers.json"
if (Test-Path $mqFile) {
    $mqJson = Get-Content $mqFile | ConvertFrom-Json
}

$allClusters = @()
$done        = @{}

# ==========================================
# SQL i FileShare — klastry Windows
# Wzor z cluster.ps1 — uzywa -Cluster $srv (bez Invoke-Command)
# ==========================================
foreach ($def in ($clustersJson.clusters | Where-Object { $_.cluster_type -ne "MQ" })) {
    $type = $def.cluster_type
    foreach ($srv in $def.servers) {
        Log "  Klaster $type : $srv"
        try {
            # Pobierz nazwe klastra (jak w Get-ClusterStatusReport.ps1)
            $cluster     = Get-Cluster -Name $srv -ErrorAction Stop
            $clusterName = $cluster.Name

            # Duplikat? (ten sam klaster z drugiego wezla)
            if ($done[$clusterName]) { Log "    Pomijam (duplikat $clusterName)"; continue }
            $done[$clusterName] = $true

            # Wezly — wzor z cluster.ps1
            $nodes = @(Get-ClusterNode -Cluster $srv -ErrorAction Stop | ForEach-Object {
                $node = $_
                try {
                    $nodeNetworks = Get-ClusterNetworkInterface -Cluster $srv -Node $node.Name
                    $ipAddresses  = ($nodeNetworks | ForEach-Object { $_.Address }) -join ", "
                } catch {
                    $ipAddresses = "N/A"
                }
                [PSCustomObject]@{
                    Name          = $node.Name
                    State         = $node.State.ToString()
                    NodeWeight    = $node.NodeWeight
                    DynamicWeight = $node.DynamicWeight
                    IPAddresses   = if ($ipAddresses) { $ipAddresses } else { "N/A" }
                }
            })

            # Role — wzor z cluster.ps1
            $roles = @(Get-ClusterGroup -Cluster $srv -ErrorAction Stop | ForEach-Object {
                $role = $_
                try {
                    $resources = Get-ClusterResource -Cluster $srv | Where-Object { $_.OwnerGroup -eq $role.Name }
                    $ipAddr    = ($resources | Where-Object { $_.ResourceType -eq "IP Address" } | ForEach-Object {
                        try { (Get-ClusterParameter -InputObject $_ -Name Address).Value } catch { "N/A" }
                    }) -join ", "
                } catch { $ipAddr = "N/A" }

                # DNS dla rol SQL
                $displayName = $role.Name
                if ($role.Name -like "*SQL*" -and $ipAddr -and $ipAddr -ne "N/A" -and $ipAddr -ne "") {
                    $sqlIP = ($ipAddr -split ", ")[0]
                    try { $displayName = ([System.Net.Dns]::GetHostEntry($sqlIP)).HostName } catch {}
                }

                [PSCustomObject]@{
                    Name        = $displayName
                    State       = $role.State.ToString()
                    OwnerNode   = $role.OwnerNode.ToString()
                    IPAddresses = if ($ipAddr) { $ipAddr } else { "N/A" }
                }
            })

            $allClusters += [PSCustomObject]@{
                ClusterName = $clusterName
                ClusterType = $type
                Status      = "Online"
                Nodes       = $nodes
                Roles       = $roles
                Error       = $null
            }
            Log "    OK: $clusterName ($($nodes.Count) wezlow, $($roles.Count) rol)"

        } catch {
            $allClusters += [PSCustomObject]@{
                ClusterName = $srv
                ClusterType = $type
                Status      = "Error"
                Nodes       = @()
                Roles       = @()
                Error       = $_.Exception.Message
            }
            Log "    FAIL: $($_.Exception.Message)"
        }
    }
}

# ==========================================
# MQ — nie sa klastrami Windows
# Invoke-Command bo dspmq/runmqsc nie maja natywnych cmdletow PS
# ==========================================
if ($mqJson) {
    foreach ($grp in $mqJson.PSObject.Properties) {
        $groupName = $grp.Name
        $servers   = @($grp.Value)
        Log "  MQ: $groupName [$($servers -join ', ')]"

        $mqNodes = @()
        $mqRoles = @()
        $ok = $false

        $mqRaw = Invoke-Command -ComputerName $servers -ErrorAction SilentlyContinue -ScriptBlock {
            $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                   Where-Object { $_.IPAddress -like "10.*" } | Select-Object -First 1).IPAddress
            $qmgrs = @()
            $mqData = dspmq 2>$null
            if ($mqData) {
                foreach ($line in $mqData) {
                    if ($line -match 'QMNAME\s*\(\s*(?<name>.*?)\s*\)\s+STATUS\s*\(\s*(?<state>.*?)\s*\)') {
                        $qmName = $Matches['name'].Trim()
                        $state  = $Matches['state'].Trim() -replace 'Dzia.+?c[ye]', 'Running'
                        $port   = ""
                        if ($state -match 'Running|Dzia') {
                            $ls = "DISPLAY LSSTATUS(*) PORT" | runmqsc $qmName 2>$null
                            if ($ls) { foreach ($l in $ls) { if ($l -match 'PORT\s*\(\s*(?<p>\d+)\s*\)') { $port = $Matches['p']; break } } }
                        }
                        $qmgrs += [PSCustomObject]@{ Name = $qmName; State = $state; OwnerNode = $env:COMPUTERNAME; IPAddresses = $port }
                    }
                }
            }
            [PSCustomObject]@{ RealName = $env:COMPUTERNAME; IP = if ($ip) { $ip } else { "N/A" }; QMgrs = $qmgrs }
        }

        foreach ($r in $mqRaw) {
            $mqNodes += [PSCustomObject]@{ Name = $r.RealName; State = "Up"; NodeWeight = 1; DynamicWeight = 1; IPAddresses = $r.IP }
            $mqRoles += @($r.QMgrs)
            $ok = $true
        }

        # Serwery ktore nie odpowiedzialy
        $okSrv = @($mqRaw | ForEach-Object { $_.PSComputerName })
        foreach ($srv in $servers) {
            if ($srv -notin $okSrv) {
                $mqNodes += [PSCustomObject]@{ Name = $srv; State = "Down"; NodeWeight = 1; DynamicWeight = 1; IPAddresses = "Brak" }
                Log "    FAIL node $srv"
            }
        }

        $allClusters += [PSCustomObject]@{
            ClusterName = $groupName
            ClusterType = "MQ"
            Status      = $(if ($ok) { "Online" } else { "Error" })
            Nodes       = $mqNodes
            Roles       = $mqRoles
            Error       = $null
        }
        Log "    MQ $groupName : $($mqNodes.Count) nodes, $($mqRoles.Count) qm"
    }
}

# --- ZAPIS ---
$online = @($allClusters | Where-Object { $_.Status -eq "Online" }).Count

@{
    LastUpdate    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    TotalClusters = $allClusters.Count
    OnlineCount   = $online
    FailedCount   = $allClusters.Count - $online
    Clusters      = $allClusters
} | ConvertTo-Json -Depth 10 | Out-File $OutputFile -Encoding UTF8 -Force

Log "KONIEC: $($allClusters.Count) klastrow (OK: $online)"
