function ClusterResourceDB($cluster) {
    Invoke-Command -ComputerName $cluster -ScriptBlock {
        $dbAgg = @()
        $shareAgg = @()

        # --- Availability Groups / bazy danych ---
        $ags = Get-ClusterResource -Cluster $clusterName |
               Where-Object ResourceType -eq 'SQL Server Availability Group'

        foreach ($ag in $ags) {
            try {
                $agInfo = Invoke-Sqlcmd -Query "
                    SELECT database_name
                    FROM sys.dm_hadr_database_replica_cluster_states
                " -ServerInstance $ag.OwnerNode -Quiet

                foreach ($row in $agInfo) {
                    $dbAgg += [pscustomobject]@{
                        Cluster           = $clusterName
                        AvailabilityGroup = $ag.Name
                        Database          = $row.database_name
                    }
                }
            } catch {
                Write-Warning "Błąd podczas pobierania danych AG z $($ag.OwnerNode): $_"
            }
        }
}


function ClusterResourceSMB($cluster) {
    Invoke-Command -ComputerName $cluster -ScriptBlock {
            $dbAgg = @()
            $shareAgg = @()

            $shares = Get-SmbShare -CimSession $clusterName -Special $false
            foreach ($s in $shares) {
                $shareAgg += [pscustomobject]@{
                    Cluster     = $clusterName
                    ShareName   = $s.Name
                    Path        = $s.Path
                    Description = $s.Description
                }

        # Zwróć dane
        return [PSCustomObject]@{
            Databases = $dbAgg
            Shares    = $shareAgg
        }
    }
}

<#
$JsonData = Get-Content  "D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data\clusters.json" | ConvertFrom-Json

$clusters = $JsonData.ClusterNames
$outDataDir = $JsonData.OutputPath


foreach ($cluster in $clusters) {

ClusterResourceDB -cluster $cluster | Export-Csv -Path "D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data\data\sql_db_details.csv" -NoTypeInformation
ClusterResourceSMB -cluster $cluster | Export-Csv -Path "D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data\data\fileShare.csv" -NoTypeInformation
}
#>