function ClusterNodeStatus($cluster) {
    Invoke-Command -ComputerName $cluster -ScriptBlock {
       Get-ClusterNode | ForEach-Object {
            $node = $_
            $nodeNetworks = Get-ClusterNetworkInterface  -Node $node.Name
            $ipAddresses = ($nodeNetworks | ForEach-Object { $_.Address }) -join ", "

            [PSCustomObject]@{
                            Name = $node.Name
                            State = $node.State
                            NodeWeight = $node.NodeWeight
                            DynamicWeight = $node.DynamicWeight
                            IPAddresses = $ipAddresses
                            }
            }
    }         
}

function SQLClusterGroupStatus($cluster) { 
    Invoke-Command -ComputerName $cluster -ScriptBlock { 
		Get-ClusterGroup | ForEach-Object { 
			$role = $_ 
			try { 
				$resources = Get-ClusterResource | Where-Object { $_.OwnerGroup -eq $role.Name } 
				$ipAddresses = ($resources | Where-Object { $_.ResourceType -eq "IP Address" } | ForEach-Object { 
			try { 
				$params = Get-ClusterParameter -InputObject $_ -Name Address 
				$params.Value 
			} 
			catch { 
			"N/A" 
		} 
    }) -join ", " 

    # Tylko dla ról SQL podmień nazwę na DNS name
    $displayName = $role.Name
    if ($role.Name -like "*SQL*" -and $ipAddresses -ne "N/A" -and $ipAddresses -ne "") {
    $sqlIP = ($ipAddresses -split ", ")[0] # Weź pierwszy IP
    if ($sqlIP) {
    try {
    $sqlDNSName = ([System.Net.Dns]::GetHostEntry($sqlIP)).HostName
    $displayName = $sqlDNSName
    } catch {
    # Jeśli nie można uzyskać DNS name, zostaw oryginalną nazwę
    $displayName = $role.Name
    }
    }
    }

    } catch { 
    $ipAddresses = "N/A" 
    $displayName = $role.Name
    } 

    [PSCustomObject]@{ 
    Name = $displayName
    State = $role.State 
    OwnerNode = $role.OwnerNode 
    IPAddresses = $ipAddresses 
    } 
    } 
    } 
}

function clusterName($cluster) {
    Invoke-Command -ComputerName $cluster -ScriptBlock {
        (Get-Cluster).name
    }
}


$JsonData = Get-Content  "D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data\clusters.json" | ConvertFrom-Json

$clusters = $JsonData.ClusterNames
$outDataDir = $JsonData.OutputPath


foreach ($cluster in $clusters) {
    $clusterName = clusterName -cluster $cluster
    
    $dataNodeStatusFile = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data\Data\" + $clusterName + "_node_status.csv"
    $dataRoleStatusFile = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data\Data\" + $clusterName + "_role_status.csv"
    
    ClusterNodeStatus -cluster $cluster | Export-Csv -Path $dataNodeStatusFile -NoTypeInformation
    SQLClusterGroupStatus -cluster $cluster | Export-Csv -Path $dataRoleStatusFile -NoTypeInformation
}