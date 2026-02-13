function FileShareClusterResourceCsv {
    param (
        [string]$FileShare
    )

    $shareAgg = @()

    try {
        $shares = Get-SmbShare -CimSession $FileShare -Special $false

        foreach ($s in $shares) {
            $shareAgg += [pscustomobject]@{
                Cluster     = $FileShare
                ShareName   = $s.Name
                Path        = $s.Path
                Description = $s.Description
            }
        }
    }
    catch {
        Write-Warning "B³¹d podczas pobierania udzia³ów z $FileShare: $_"
    }

    return $shareAgg
}

# Wczytaj dane z JSON
$JsonData = Get-Content "D:\PROD_REPO_DATA\IIS\prodHealtchCheck\config\clusters.json" | ConvertFrom-Json
$files = $JsonData.FileShare

# Usuñ istniej¹cy plik CSV, jeœli istnieje
$csvPath = "D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data\fileShare.csv"
if (Test-Path $csvPath) {
    Remove-Item $csvPath
    Write-Host "Usuniêto istniej¹cy plik CSV."
} else {
    Write-Host "Plik CSV nie istnieje — mo¿na tworzyæ nowy."
}

# Zapisz dane do CSV
foreach ($file in $files) {
    FileShareClusterResourceCsv -FileShare $file | Export-Csv $csvPath -Append -NoTypeInformation
}
