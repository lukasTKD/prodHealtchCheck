# =============================================================================
# Collect-WMQClusterStatus.ps1
# Zbiera status klastrów IBM MQ i zapisuje w formacie infra_ClustersWMQ.json
# =============================================================================

param(
    [string]$ConfigPath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck\config\mq_servers.json",
    [string]$OutputPath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data\infra_ClustersWMQ.json"
)

$StartTime = Get-Date

# Wczytaj konfigurację klastrów MQ
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Brak pliku konfiguracji: $ConfigPath"
    exit 1
}

$MQClusters = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# Przygotuj strukturę wynikową
$Clusters = @()
$OnlineCount = 0
$FailedCount = 0

# Iteruj po klastrach
foreach ($ClusterName in $MQClusters.PSObject.Properties.Name) {
    $Servers = $MQClusters.$ClusterName

    $ClusterNodes = @()
    $ClusterRoles = @()
    $ClusterError = $null
    $ClusterOnline = $true

    foreach ($ServerName in $Servers) {
        $NodeState = "Down"
        $NodeIP = ""

        try {
            # Sprawdź czy serwer odpowiada
            $PingResult = Test-Connection -ComputerName $ServerName -Count 1 -Quiet -ErrorAction SilentlyContinue

            if ($PingResult) {
                $NodeState = "Up"

                # Pobierz dane z serwera zdalnie
                $RemoteData = Invoke-Command -ComputerName $ServerName -ErrorAction Stop -ScriptBlock {
                    $Result = @{
                        NodeName = $env:COMPUTERNAME
                        IPAddress = ""
                        QueueManagers = @()
                    }

                    # Pobierz IP
                    try {
                        $IP = (Get-NetIPAddress -AddressFamily IPv4 -Type Unicast |
                               Where-Object { $_.InterfaceAlias -notmatch "Loopback|Pseudo" -and $_.IPAddress -notmatch "^169\." }).IPAddress
                        if ($IP -is [array]) { $IP = $IP[0] }
                        $Result.IPAddress = $IP
                    } catch {
                        $Result.IPAddress = "N/A"
                    }

                    # Pobierz QManagery
                    try {
                        $dspmqOutput = dspmq 2>$null

                        if ($dspmqOutput) {
                            foreach ($line in $dspmqOutput) {
                                if ($line -match 'QMNAME\((?<name>[^\)]+)\)\s+STATUS\((?<status>[^\)]+)\)') {
                                    $QMName = $Matches['name']
                                    $QMStatus = $Matches['status']

                                    # Normalizuj status
                                    $NormalizedStatus = switch -Regex ($QMStatus) {
                                        'Running|Dzia' { "Running" }
                                        'Ended|Stopped|Zako' { "Stopped" }
                                        default { $QMStatus }
                                    }

                                    # Pobierz port listenera
                                    $Port = ""
                                    try {
                                        # Sprawdź czy QM działa przed próbą pobrania portu
                                        if ($NormalizedStatus -eq "Running") {
                                            $ListenerOutput = echo "DISPLAY LISTENER(*) PORT" | runmqsc $QMName 2>$null
                                            if ($ListenerOutput -match 'PORT\((\d+)\)') {
                                                $Port = $Matches[1]
                                            }

                                            # Alternatywnie sprawdź lsstatus
                                            if (-not $Port) {
                                                $LsStatusOutput = echo "DISPLAY LSSTATUS(*) PORT" | runmqsc $QMName 2>$null
                                                if ($LsStatusOutput -match 'PORT\((\d+)\)') {
                                                    $Port = $Matches[1]
                                                }
                                            }
                                        }
                                    } catch {}

                                    $Result.QueueManagers += @{
                                        Name = $QMName
                                        Status = $NormalizedStatus
                                        Port = $Port
                                    }
                                }
                            }
                        }
                    } catch {
                        # Brak MQ lub błąd
                    }

                    return $Result
                }

                $NodeIP = $RemoteData.IPAddress

                # Dodaj QManagery jako Role
                foreach ($QM in $RemoteData.QueueManagers) {
                    $RoleState = if ($QM.Status -eq "Running") { "Online" } else { "Offline" }

                    $ClusterRoles += @{
                        Name = $QM.Name
                        State = $RoleState
                        OwnerNode = $RemoteData.NodeName
                        IPAddresses = $NodeIP
                        Port = $QM.Port
                    }
                }
            } else {
                $ClusterOnline = $false
            }
        } catch {
            $NodeState = "Down"
            $ClusterOnline = $false
            if (-not $ClusterError) {
                $ClusterError = "Blad polaczenia z $ServerName : $($_.Exception.Message)"
            }
        }

        # Dodaj węzeł
        $ClusterNodes += @{
            Name = $ServerName.ToUpper()
            State = $NodeState
            IPAddresses = $NodeIP
        }
    }

    # Sprawdź czy klaster ma błędy
    $AllNodesDown = ($ClusterNodes | Where-Object { $_.State -eq "Up" }).Count -eq 0
    if ($AllNodesDown) {
        $ClusterError = "Wszystkie wezly klastra niedostepne"
        $FailedCount++
    } else {
        $OnlineCount++
    }

    # Dodaj klaster
    $Clusters += @{
        ClusterName = $ClusterName
        ClusterType = "MQ"
        Error = $ClusterError
        Nodes = $ClusterNodes
        Roles = $ClusterRoles
    }
}

$EndTime = Get-Date
$Duration = ($EndTime - $StartTime).TotalSeconds

# Zbuduj wynikowy obiekt
$Result = @{
    LastUpdate = $EndTime.ToString("yyyy-MM-dd HH:mm:ss")
    CollectionDuration = [math]::Round($Duration, 1).ToString()
    TotalClusters = $Clusters.Count
    OnlineCount = $OnlineCount
    FailedCount = $FailedCount
    Clusters = $Clusters
}

# Zapisz do pliku JSON
$Result | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputPath -Encoding UTF8 -Force

Write-Host "Zebrano dane z $($Clusters.Count) klastrow MQ w $([math]::Round($Duration, 1))s" -ForegroundColor Green
Write-Host "Zapisano do: $OutputPath" -ForegroundColor Cyan
