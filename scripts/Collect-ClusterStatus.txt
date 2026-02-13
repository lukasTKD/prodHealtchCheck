# Collect-ClusterStatus.ps1
# Zbiera status klastrow Windows + serwery MQ -> cluster_nodes.csv + cluster_roles.csv
# Wzor z: Untitled6.ps1, MQ_servers.ps1, MQ_Qmanagers.ps1
# ZERO JSON — tylko Import-Csv i Export-Csv

# --- SCIEZKI Z app-config.json ---
$ScriptDir  = Split-Path $PSScriptRoot -Parent
$appConfig  = (Get-Content "$ScriptDir\app-config.json" -Raw).Trim() | ConvertFrom-Json
$DataPath   = $appConfig.paths.dataPath
$ConfigPath = $appConfig.paths.configPath
$LogsPath   = $appConfig.paths.logsPath

if (!(Test-Path $DataPath)) { New-Item -ItemType Directory -Path $DataPath -Force | Out-Null }
if (!(Test-Path $LogsPath)) { New-Item -ItemType Directory -Path $LogsPath -Force | Out-Null }

$LogFile = "$LogsPath\ServerHealthMonitor.log"
function Log($msg) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [CLUSTERS] $msg" | Out-File $LogFile -Append -Encoding UTF8 }

Log "START Collect-ClusterStatus"

# --- KONFIGURACJA Z CSV (pliki wskazane w app-config.json) ---
$clustersCfg  = Import-Csv "$ConfigPath\$($appConfig.scripts.'Collect-ClusterStatus'.sourceFile)"
$mqServersCfg = Import-Csv "$ConfigPath\$($appConfig.scripts.'Collect-ClusterStatus'.mqServersFile)"

$allNodes = @()
$allRoles = @()
$done = @{}


# ==========================================
# 1. KLASTRY SQL i FileShare
# Identycznie jak Untitled6.ps1
# ==========================================
$sqlFsServers = @($clustersCfg | Where-Object { $_.ClusterType -ne "MQ" })
Write-Host "Klastry SQL/FS: $($sqlFsServers.Count) serwerow"
Log "Klastry SQL/FS: $($sqlFsServers.Count) serwerow"

foreach ($entry in $sqlFsServers) {
    $srv  = $entry.ServerName
    $type = $entry.ClusterType
    Write-Host "  $type : $srv"
    Log "  Klaster $type : $srv"

    try {
        # Nazwa klastra
        $clName = Invoke-Command -ComputerName $srv -ErrorAction Stop -ScriptBlock {
            (Get-Cluster).Name
        }

        if ($done[$clName]) { Write-Host "    Pomijam duplikat $clName"; Log "    Duplikat $clName"; continue }
        $done[$clName] = $true

        # NODES — ClusterNodeStatus z Untitled6.ps1
        $nodes = Invoke-Command -ComputerName $srv -ErrorAction Stop -ScriptBlock {
            Get-ClusterNode | ForEach-Object {
                $node = $_
                $nodeNetworks = Get-ClusterNetworkInterface -Node $node.Name
                $ipAddresses = ($nodeNetworks | ForEach-Object { $_.Address }) -join ", "
                [PSCustomObject]@{
                    Name          = $node.Name
                    State         = $node.State.ToString()
                    NodeWeight    = $node.NodeWeight
                    DynamicWeight = $node.DynamicWeight
                    IPAddresses   = $ipAddresses
                }
            }
        }
        foreach ($n in $nodes) {
            $allNodes += [PSCustomObject]@{
                ClusterName   = $clName
                ClusterType   = $type
                NodeName      = $n.Name
                State         = $n.State
                NodeWeight    = $n.NodeWeight
                DynamicWeight = $n.DynamicWeight
                IPAddresses   = $n.IPAddresses
            }
        }

        # ROLES — SQLClusterGroupStatus z Untitled6.ps1
        $roles = Invoke-Command -ComputerName $srv -ErrorAction Stop -ScriptBlock {
            Get-ClusterGroup | ForEach-Object {
                $role = $_
                try {
                    $resources = Get-ClusterResource | Where-Object { $_.OwnerGroup -eq $role.Name }
                    $ipAddresses = ($resources | Where-Object { $_.ResourceType -eq "IP Address" } | ForEach-Object {
                        try { (Get-ClusterParameter -InputObject $_ -Name Address).Value } catch { "N/A" }
                    }) -join ", "
                } catch { $ipAddresses = "N/A" }

                $displayName = $role.Name
                if ($role.Name -like "*SQL*" -and $ipAddresses -ne "N/A" -and $ipAddresses -ne "") {
                    $sqlIP = ($ipAddresses -split ", ")[0]
                    if ($sqlIP) {
                        try { $displayName = ([System.Net.Dns]::GetHostEntry($sqlIP)).HostName } catch {}
                    }
                }

                [PSCustomObject]@{
                    Name        = $displayName
                    State       = $role.State.ToString()
                    OwnerNode   = $role.OwnerNode.ToString()
                    IPAddresses = $ipAddresses
                }
            }
        }
        foreach ($r in $roles) {
            $allRoles += [PSCustomObject]@{
                ClusterName = $clName
                ClusterType = $type
                RoleName    = $r.Name
                State       = $r.State
                OwnerNode   = $r.OwnerNode
                IPAddresses = $r.IPAddresses
            }
        }

        Write-Host "    OK: $clName ($(@($nodes).Count) nodes, $(@($roles).Count) roles)" -ForegroundColor Green
        Log "    OK: $clName ($(@($nodes).Count) nodes, $(@($roles).Count) roles)"

    } catch {
        Write-Host "    BLAD: $($_.Exception.Message)" -ForegroundColor Red
        Log "    BLAD: $($_.Exception.Message)"
    }
}


# ==========================================
# 2. SERWERY MQ
# Identycznie jak MQ_servers.ps1 + MQ_Qmanagers.ps1
# ==========================================
$mqGroups = $mqServersCfg | Group-Object GroupName
Write-Host "`nMQ: $($mqGroups.Count) grup"
Log "MQ: $($mqGroups.Count) grup"

foreach ($grp in $mqGroups) {
    $groupName = $grp.Name
    $servers   = @($grp.Group | ForEach-Object { $_.ServerName })
    Write-Host "  $groupName [$($servers -join ', ')]"
    Log "  MQ: $groupName [$($servers -join ', ')]"

    # NODES — MQ_servers.ps1
    foreach ($srv in $servers) {
        try {
            $result = Invoke-Command -ComputerName $srv -ErrorAction Stop -ScriptBlock {
                $IP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like "10.*" } | Select-Object -First 1).IPAddress
                [PSCustomObject]@{ IP = if ($IP) { $IP } else { "N/A" }; RealName = $env:COMPUTERNAME }
            }
            $allNodes += [PSCustomObject]@{
                ClusterName   = $groupName
                ClusterType   = "MQ"
                NodeName      = $result.RealName
                State         = "Up"
                NodeWeight    = 1
                DynamicWeight = 1
                IPAddresses   = $result.IP
            }
            Write-Host "    Node $($result.RealName) = Up ($($result.IP))"
        } catch {
            $allNodes += [PSCustomObject]@{
                ClusterName   = $groupName
                ClusterType   = "MQ"
                NodeName      = $srv
                State         = "Down"
                NodeWeight    = 1
                DynamicWeight = 1
                IPAddresses   = "Brak"
            }
            Write-Host "    Node $srv = Down" -ForegroundColor Red
            Log "    BLAD node $srv : $($_.Exception.Message)"
        }
    }

    # ROLES (QManagery) — MQ_Qmanagers.ps1
    $mqResults = Invoke-Command -ComputerName $servers -ErrorAction SilentlyContinue -ScriptBlock {
        $NodeName = $env:COMPUTERNAME
        try {
            $mqData = dspmq 2>$null
            if ($mqData) {
                $mqData | ForEach-Object {
                    if ($_ -match 'QMNAME\s*\(\s*(?<name>.*?)\s*\)\s+STATUS\s*\(\s*(?<state>.*?)\s*\)') {
                        $qmName   = $Matches['name'].Trim()
                        $rawState = $Matches['state'].Trim() -replace 'Dzia.+?c[ye]', 'Running'
                        $Port = ""
                        if ($rawState -match 'Running|Dzia') {
                            $listenerData = "DISPLAY LSSTATUS(*) PORT" | runmqsc $qmName 2>$null
                            if ($listenerData) {
                                foreach ($lLine in $listenerData) {
                                    if ($lLine -match 'PORT\s*\(\s*(?<p>\d+)\s*\)') { $Port = $Matches['p']; break }
                                }
                            }
                        }
                        [PSCustomObject]@{ Name = $qmName; State = $rawState; OwnerNode = $NodeName; IPAddresses = $Port }
                    }
                }
            }
        } catch {
            [PSCustomObject]@{ Name = "ERROR"; State = "Blad"; OwnerNode = $NodeName; IPAddresses = "Brak" }
        }
    }
    foreach ($r in $mqResults) {
        $allRoles += [PSCustomObject]@{
            ClusterName = $groupName
            ClusterType = "MQ"
            RoleName    = $r.Name
            State       = $r.State
            OwnerNode   = $r.OwnerNode
            IPAddresses = $r.IPAddresses
        }
    }
    Write-Host "    QManagery: $(@($mqResults).Count)" -ForegroundColor Green
    Log "    MQ $groupName : QMgrs=$(@($mqResults).Count)"
}


# ==========================================
# ZAPIS DO CSV
# ==========================================
$allNodes | Export-Csv -Path "$DataPath\cluster_nodes.csv" -NoTypeInformation -Encoding UTF8
$allRoles | Export-Csv -Path "$DataPath\cluster_roles.csv" -NoTypeInformation -Encoding UTF8

Write-Host "`n=== GOTOWE ===" -ForegroundColor Green
Write-Host "cluster_nodes.csv: $($allNodes.Count) wierszy"
Write-Host "cluster_roles.csv: $($allRoles.Count) wierszy"
Log "KONIEC: nodes=$($allNodes.Count), roles=$($allRoles.Count)"
