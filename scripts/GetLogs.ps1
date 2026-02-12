param(
    [string]$ServerName,
    [string]$LogName,
    [int]$MinutesBack
)

$startTime = (Get-Date).AddMinutes(-$MinutesBack)

try {
    $events = Get-WinEvent -ComputerName $ServerName -FilterHashtable @{
        LogName = $LogName
        StartTime = $startTime
    } -ErrorAction Stop | Select-Object @{Name='TimeCreated';Expression={$_.TimeCreated.ToString("yyyy-MM-ddTHH:mm:ss")}}, LevelDisplayName, Id, ProviderName, Message

    if ($events) {
        $events | ConvertTo-Json -Depth 3 -Compress
    } else {
        "[]"
    }
} catch [System.Exception] {
    if ($_.Exception.Message -like "*No events were found*") {
        "[]"
    } else {
        throw $_
    }
}
