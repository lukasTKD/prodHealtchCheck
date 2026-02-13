# Collect-ClusterStatus.ps1
# Prosty skrypt — wzor z Untitled6.ps1 + MQ_servers.ps1 + MQ_Qmanagers.ps1

# --- SCIEZKI ---
$ScriptDir  = Split-Path $PSScriptRoot -Parent
$appConfig  = Get-Content "$ScriptDir\app-config.json" -Raw | ConvertFrom-Json
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
$clustersJson = Get-Content "$ConfigPath\clusters.json" -Raw | ConvertFrom-Json
$mqJson       = $null
$mqFile       = "$ConfigPath\mq_servers.json"
if (Test-Path $mqFile) { $mqJson = Get-Content $mqFile -Raw | ConvertFrom-Json }

$allClusters  = @()
$done         = @{}

# ==========================================
# SQL i FileShare — prawdziwe klastry Windows
# Identycznie jak Untitled6.ps1
# ==========================================
foreach ($def in ($clustersJson.clusters | Where-Object { $_.cluster_type -ne "MQ" })) {
    $type = $def.cluster_type
    foreach ($srv in $def.servers) {
        Log "  Klaster $type : $srv"
        try {
            # JEDNO wywolanie — wszystko naraz (nazwa klastra + wezly + role)
            $data = Invoke-Command -ComputerName $srv -ErrorAction Stop -ScriptBlock {
                $clName = (Get-Cluster).Name

                $nodes = @(Get-ClusterNode | ForEach-Object {
                    $n = $_
                    $ips = (Get-ClusterNetworkInterface -Node $n.Name -ErrorAction SilentlyContinue | ForEach-Object { $_.Address }) -join ", "
                    [PSCustomObject]@{
                        Name          = $n.Name
                        State         = $n.State.ToString()
                        NodeWeight    = $n.NodeWeight
                        DynamicWeight = $n.DynamicWeight
                        IPAddresses   = if ($ips) { $ips } else { "N/A" }
                    }
                })

                $roles = @(Get-ClusterGroup | ForEach-Object {
                    $role = $_
                    try {
                        $resources = Get-ClusterResource | Where-Object { $_.OwnerGroup -eq $role.Name }
                        $ipAddr    = ($resources | Where-Object { $_.ResourceType -eq "IP Address" } | ForEach-Object {
                            try { (Get-ClusterParameter -InputObject $_ -Name Address).Value } catch { "N/A" }
                        }) -join ", "
                    } catch { $ipAddr = "N/A" }

                    $displayName = $role.Name
                    if ($role.Name -like "*SQL*" -and $ipAddr -and $ipAddr -ne "N/A" -and $ipAddr -ne "") {
                        $sqlIP = ($ipAddr -split ", ")[0]
                        try { $displayName = ([System.Net.Dns]::GetHostEntry($sqlIP)).HostName } catch {}
                    }

                    [PSCustomObject]@{
                        Name        = $displayName
                        State       = $role.State.ToString()
                        OwnerNode   = $role.OwnerNode.ToString()
                        IPAddresses = $ipAddr
                    }
                })

                [PSCustomObject]@{ ClusterName = $clName; Nodes = $nodes; Roles = $roles }
            }

            # Pomijaj duplikaty (ten sam klaster z drugiego wezla)
            if ($done[$data.ClusterName]) { Log "    Pomijam (duplikat $($data.ClusterName))"; continue }
            $done[$data.ClusterName] = $true

            $allClusters += [PSCustomObject]@{
                ClusterName = $data.ClusterName; ClusterType = $type; Status = "Online"; FQDN = $srv
                Nodes = @($data.Nodes); Roles = @($data.Roles); Error = $null
            }
            Log "    OK: $($data.ClusterName) ($(@($data.Nodes).Count) wezlow, $(@($data.Roles).Count) rol)"

        } catch {
            $allClusters += [PSCustomObject]@{
                ClusterName = $srv; ClusterType = $type; Status = "Error"; FQDN = $srv
                Nodes = @(); Roles = @(); Error = $_.Exception.Message
            }
            Log "    FAIL: $($_.Exception.Message)"
        }
    }
}

# ==========================================
# MQ — NIE sa klastrami Windows
# Wzor z MQ_servers.ps1 + MQ_Qmanagers.ps1
# ==========================================
if ($mqJson) {
    foreach ($grp in $mqJson.PSObject.Properties) {
        $groupName = $grp.Name
        $servers   = @($grp.Value)
        Log "  MQ: $groupName [$($servers -join ', ')]"

        $mqNodes = @()
        $mqRoles = @()
        $ok = $false

        # JEDNO wywolanie na WSZYSTKIE serwery grupy — rownolegle
        $mqRaw = Invoke-Command -ComputerName $servers -ErrorAction SilentlyContinue -ErrorVariable mqErrors -ScriptBlock {
            $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like "10.*" } | Select-Object -First 1).IPAddress
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
            ClusterName = $groupName; ClusterType = "MQ"; Status = $(if ($ok) { "Online" } else { "Error" }); FQDN = ($servers -join ", ")
            Nodes = $mqNodes; Roles = $mqRoles; Error = $null
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
