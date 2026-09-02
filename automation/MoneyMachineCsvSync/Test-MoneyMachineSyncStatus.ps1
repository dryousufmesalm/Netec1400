[CmdletBinding(DefaultParameterSetName='Explicit')]
param(
    [Parameter(Mandatory,ParameterSetName='Explicit')][string]$OneDriveRoot,
    [Parameter(Mandatory,ParameterSetName='Explicit')][string[]]$ExpectedAccount,
    [Parameter(ParameterSetName='Explicit')][Parameter(ParameterSetName='Configured')][double]$FreshnessHours = 26,
    [Parameter(Mandatory,ParameterSetName='Configured')][string]$ConfigPath,
    [Parameter(ParameterSetName='Configured')][string]$RuntimeRoot,
    [Parameter(Mandatory,ParameterSetName='Library')][switch]$AsLibrary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AmmarTradingDestinationPath {
    param(
        [Parameter(Mandatory)][string]$OneDriveRoot,
        [Parameter(Mandatory)][string]$AccountNumber
    )

    Join-Path $OneDriveRoot (Join-Path 'amartrading' (Join-Path ("Account_{0}" -f $AccountNumber) 'Baskets.csv'))
}

function Get-AmmarTradingHeartbeatStatus {
    param(
        [Parameter(Mandatory)][string]$OneDriveRoot,
        [Parameter(Mandatory)][string]$AccountNumber,
        [Parameter(Mandatory)][double]$FreshnessHours
    )

    $result = [ordered]@{
        AccountNumber = $AccountNumber
        Status = 'Error'
        StatusCode = 'HeartbeatError'
        IsFresh = $false
        HeartbeatAgeHours = $null
        Message = ''
    }
    try {
        if([string]::IsNullOrWhiteSpace($AccountNumber)) { throw 'Expected account number is empty.' }
        $destination = Get-AmmarTradingDestinationPath -OneDriveRoot $OneDriveRoot -AccountNumber $AccountNumber
        $statusPath = Join-Path (Split-Path -Parent $destination) 'SyncStatus.json'
        if(-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
            $result.StatusCode = 'MissingHeartbeat'
            throw 'Receiver heartbeat is missing.'
        }
        $heartbeat = Get-Content -LiteralPath $statusPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if([string]$heartbeat.AccountNumber -cne $AccountNumber) {
            $result.StatusCode = 'AccountMismatch'
            throw 'Heartbeat account does not match the expected folder account.'
        }
        if([string]$heartbeat.Status -cne 'Success') {
            $result.StatusCode = 'PublisherError'
            throw "Heartbeat status is '$($heartbeat.Status)' instead of Success."
        }
        if([bool]$heartbeat.CloudDeliveryVerified) {
            $result.StatusCode = 'InvalidCloudClaim'
            throw 'Publisher heartbeat must not claim cloud delivery verification.'
        }

        $publishedUtc = [DateTimeOffset]::MinValue
        $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        if(-not [DateTimeOffset]::TryParse([string]$heartbeat.PublishedUtc, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$publishedUtc)) {
            $result.StatusCode = 'InvalidPublishedUtc'
            throw 'Heartbeat PublishedUtc is invalid.'
        }
        $ageHours = ([DateTimeOffset]::UtcNow - $publishedUtc).TotalHours
        $result.HeartbeatAgeHours = [Math]::Round($ageHours, 3)
        if($ageHours -lt -0.0833) {
            $result.StatusCode = 'FutureHeartbeat'
            throw 'Heartbeat PublishedUtc is more than five minutes in the future.'
        }
        if($ageHours -gt $FreshnessHours) {
            $result.StatusCode = 'StaleHeartbeat'
            throw "Heartbeat is stale: $([Math]::Round($ageHours, 2)) hours old."
        }

        $result.Status = 'Success'
        $result.StatusCode = 'Fresh'
        $result.IsFresh = $true
        $result.Message = 'Receiver heartbeat is present and fresh.'
    } catch {
        $result.Message = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Get-AmmarTradingTaskEvidence {
    $taskNames = @(
        'MoneyMachine-Baskets-To-OneDrive-Daily',
        'MoneyMachine-Baskets-To-OneDrive-StartupCatchup'
    )
    if(-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) -or
       -not (Get-Command Get-ScheduledTaskInfo -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ TaskState='Unavailable'; TaskResultCode='Unavailable' }
    }

    $evidence = [System.Collections.Generic.List[object]]::new()
    foreach($taskName in $taskNames) {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if($null -eq $task) {
            $evidence.Add([pscustomobject]@{ Name=$taskName; State='Missing'; Result='NotRun' })
            continue
        }
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
        $resultCode = if($null -eq $taskInfo) { 'Unknown' } else { [string]$taskInfo.LastTaskResult }
        $evidence.Add([pscustomobject]@{ Name=$taskName; State=[string]$task.State; Result=$resultCode })
    }

    $present = @($evidence | Where-Object State -ne 'Missing').Count
    $taskState = if($present -eq $taskNames.Count) { 'Registered' } elseif($present -gt 0) { 'Partial' } else { 'NotRegistered' }
    $resultCodes = @($evidence | ForEach-Object { '{0}:{1}' -f ([IO.Path]::GetFileName($_.Name)),$_.Result }) -join ';'
    return [pscustomobject]@{ TaskState=$taskState; TaskResultCode=$resultCodes }
}

function Get-AmmarTradingConfiguredSyncStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$RuntimeRoot,
        [double]$FreshnessHours = 26
    )

    if($FreshnessHours -le 0) { throw 'FreshnessHours must be greater than zero.' }
    if(-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return @() }
    if([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath)) }

    $schemaModule = Join-Path $PSScriptRoot 'MoneyMachineCsvSchemaV3.psm1'
    if(-not (Test-Path -LiteralPath $schemaModule -PathType Leaf)) { throw 'The schema status component is missing.' }
    Import-Module -Name $schemaModule -Force -ErrorAction Stop
    $setupModule = Join-Path $PSScriptRoot 'MoneyMachineSyncSetup.psm1'
    if(-not (Test-Path -LiteralPath $setupModule -PathType Leaf)) { throw 'The path status component is missing.' }
    Import-Module -Name $setupModule -ErrorAction Stop
    $taskEvidence = Get-AmmarTradingTaskEvidence
    $accounts = [System.Collections.Generic.List[object]]::new()
    foreach($configuration in @(Import-Csv -LiteralPath $ConfigPath -ErrorAction Stop)) {
        $accountNumber = ([string]$configuration.ExpectedMT4Login).Trim()
        if($accountNumber -notmatch '^\d{4,20}$') { continue }
        $configuredRoot = $null
        try {
            $configuredRoot = Resolve-AmmarTradingOneDriveRoot -Path ([string]$configuration.OneDriveRoot)
        } catch {
            $accounts.Add([pscustomobject][ordered]@{
                AccountNumber = $accountNumber
                BrokerName = ''
                SchemaVersion = ''
                SourceCsv = ''
                Destination = ''
                LocalPublished = $false
                LastWriteUtc = $null
                Freshness = 'Unknown'
                Status = 'Error'
                StatusCode = 'UntrustedOneDriveRoot'
                TaskState = [string]$taskEvidence.TaskState
                TaskResultCode = [string]$taskEvidence.TaskResultCode
                FailureReason = 'The configured OneDrive root is no longer trusted.'
            })
            continue
        }
        $destination = Get-AmmarTradingDestinationPath -OneDriveRoot $configuredRoot -AccountNumber $accountNumber
        $heartbeat = Get-AmmarTradingHeartbeatStatus -OneDriveRoot $configuredRoot -AccountNumber $accountNumber -FreshnessHours $FreshnessHours
        $localPublished = Test-Path -LiteralPath $destination -PathType Leaf
        $destinationItem = if($localPublished) { Get-Item -LiteralPath $destination -ErrorAction SilentlyContinue } else { $null }
        $sourceCsv = [Environment]::ExpandEnvironmentVariables(([string]$configuration.SourceCsv).Trim())
        $identity = $null
        if(Test-Path -LiteralPath $sourceCsv -PathType Leaf) {
            try { $identity = Get-AmmarTradingCsvIdentity -Path $sourceCsv } catch { $identity = $null }
        }
        $statusCode = if(-not $localPublished -and $heartbeat.StatusCode -ceq 'Fresh') { 'DestinationMissing' } else { [string]$heartbeat.StatusCode }
        $status = if($localPublished -and $heartbeat.Status -ceq 'Success') { 'Success' } else { 'Error' }
        $accounts.Add([pscustomobject][ordered]@{
            AccountNumber = $accountNumber
            BrokerName = if($null -eq $identity) { '' } else { [string]$identity.BrokerName }
            SchemaVersion = if($null -eq $identity) { '' } else { [string]$identity.SchemaVersion }
            SourceCsv = $sourceCsv
            Destination = $destination
            LocalPublished = $localPublished
            LastWriteUtc = if($null -eq $destinationItem) { $null } else { $destinationItem.LastWriteTimeUtc.ToString('o') }
            Freshness = if([bool]$heartbeat.IsFresh) { 'Fresh' } elseif($heartbeat.StatusCode -ceq 'StaleHeartbeat') { 'Stale' } else { 'Unknown' }
            Status = $status
            StatusCode = $statusCode
            TaskState = [string]$taskEvidence.TaskState
            TaskResultCode = [string]$taskEvidence.TaskResultCode
            FailureReason = if($status -ceq 'Success') { '' } else { [string]$heartbeat.Message }
        })
    }
    return @($accounts)
}

if($AsLibrary) { return }

if($FreshnessHours -le 0) { throw 'FreshnessHours must be greater than zero.' }
if($PSCmdlet.ParameterSetName -ceq 'Configured') {
    $configuredResults = @(Get-AmmarTradingConfiguredSyncStatus -ConfigPath $ConfigPath -RuntimeRoot $RuntimeRoot -FreshnessHours $FreshnessHours)
    [pscustomobject]@{ Accounts=$configuredResults } | ConvertTo-Json -Depth 6
    if(@($configuredResults | Where-Object Status -eq 'Error').Count -gt 0) { exit 1 }
    exit 0
}

if(-not (Test-Path -LiteralPath $OneDriveRoot -PathType Container)) { throw "OneDrive root not found: $OneDriveRoot" }
$results = [System.Collections.Generic.List[object]]::new()
foreach($account in $ExpectedAccount) {
    $results.Add((Get-AmmarTradingHeartbeatStatus -OneDriveRoot $OneDriveRoot -AccountNumber ([string]$account).Trim() -FreshnessHours $FreshnessHours))
}
@($results | Select-Object AccountNumber,Status,IsFresh,HeartbeatAgeHours,Message) | ConvertTo-Json -Depth 4
if(@($results | Where-Object Status -eq 'Error').Count -gt 0) { exit 1 }
exit 0
