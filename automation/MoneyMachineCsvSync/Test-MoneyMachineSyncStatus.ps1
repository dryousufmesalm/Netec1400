[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OneDriveRoot,
    [Parameter(Mandatory)][string[]]$ExpectedAccount,
    [double]$FreshnessHours = 26
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AmmarTradingDestinationPath {
    param(
        [Parameter(Mandatory)][string]$OneDriveRoot,
        [Parameter(Mandatory)][string]$AccountNumber
    )

    Join-Path $OneDriveRoot (Join-Path 'AmmarTrading' (Join-Path ("Account_{0}" -f $AccountNumber) 'Baskets.csv'))
}

if($FreshnessHours -le 0) { throw 'FreshnessHours must be greater than zero.' }
if(-not (Test-Path -LiteralPath $OneDriveRoot -PathType Container)) { throw "OneDrive root not found: $OneDriveRoot" }

$results = [System.Collections.Generic.List[object]]::new()
$hasFailure = $false
foreach($account in $ExpectedAccount) {
    $accountNumber = ([string]$account).Trim()
    $result = [ordered]@{
        AccountNumber = $accountNumber
        Status = 'Error'
        IsFresh = $false
        HeartbeatAgeHours = $null
        Message = ''
    }
    try {
        if([string]::IsNullOrWhiteSpace($accountNumber)) { throw 'Expected account number is empty.' }
        $destination = Get-AmmarTradingDestinationPath -OneDriveRoot $OneDriveRoot -AccountNumber $accountNumber
        $statusPath = Join-Path (Split-Path -Parent $destination) 'SyncStatus.json'
        if(-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) { throw 'Receiver heartbeat is missing.' }
        $heartbeat = Get-Content -LiteralPath $statusPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if([string]$heartbeat.AccountNumber -cne $accountNumber) { throw 'Heartbeat account does not match the expected folder account.' }
        if([string]$heartbeat.Status -cne 'Success') { throw "Heartbeat status is '$($heartbeat.Status)' instead of Success." }
        if([bool]$heartbeat.CloudDeliveryVerified) { throw 'Publisher heartbeat must not claim cloud delivery verification.' }

        $publishedUtc = [DateTimeOffset]::MinValue
        $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        if(-not [DateTimeOffset]::TryParse([string]$heartbeat.PublishedUtc, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$publishedUtc)) {
            throw 'Heartbeat PublishedUtc is invalid.'
        }
        $ageHours = ([DateTimeOffset]::UtcNow - $publishedUtc).TotalHours
        $result.HeartbeatAgeHours = [Math]::Round($ageHours, 3)
        if($ageHours -lt -0.0833) { throw 'Heartbeat PublishedUtc is more than five minutes in the future.' }
        if($ageHours -gt $FreshnessHours) { throw "Heartbeat is stale: $([Math]::Round($ageHours, 2)) hours old." }

        $result.Status = 'Success'
        $result.IsFresh = $true
        $result.Message = 'Receiver heartbeat is present and fresh.'
    } catch {
        $hasFailure = $true
        $result.Message = $_.Exception.Message
    }
    $results.Add([pscustomobject]$result)
}

@($results) | ConvertTo-Json -Depth 4
if($hasFailure) { exit 1 }
exit 0
