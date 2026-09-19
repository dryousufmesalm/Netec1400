[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$StartupCatchup,
    [switch]$AsLibrary,
    [int]$StableCheckSeconds = 2,
    [int]$MaxRetries = 3,
    [int]$MutexWaitMilliseconds = 30000,
    [string]$RuntimeRoot,
    [string[]]$AccountNumbers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $PSCommandPath
if([string]::IsNullOrWhiteSpace($ScriptRoot)) { throw 'Could not resolve the sync script directory.' }
if([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $ScriptRoot 'accounts.csv' }
if([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ScriptRoot }
$schemaModule = Join-Path $ScriptRoot 'MoneyMachineCsvSchemaV3.psm1'
if(-not (Test-Path -LiteralPath $schemaModule -PathType Leaf)) { throw "Schema module not found: $schemaModule" }
Import-Module -Name $schemaModule -Force -ErrorAction Stop
$setupModule = Join-Path $ScriptRoot 'MoneyMachineSyncSetup.psm1'
if(-not (Test-Path -LiteralPath $setupModule -PathType Leaf)) { throw 'The sync path validation component is unavailable.' }
if(-not (Get-Command Resolve-AmmarTradingOneDriveRoot -ErrorAction SilentlyContinue)) {
    Import-Module -Name $setupModule -ErrorAction Stop
}

function Write-SyncLog {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO','ERROR','FATAL')][string]$Level,
        [Parameter(Mandatory)][ValidateSet('Published','AccountDisabled','AlreadyPublished','MissingConfiguration','UntrustedOneDriveRoot','SourceUnavailable','SourceUnstable','SchemaValidationFailed','PublicationFailed','FatalSyncFailure')][string]$Code,
        [string]$AccountNumber = '',
        [int]$RowCount = -1,
        [int]$Attempt = 0,
        [string]$RuntimeRoot = $ScriptRoot
    )
    $logDir = Join-Path $RuntimeRoot 'logs'
    if(-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $safeAccount = if($AccountNumber -match '^\d{4,20}$') { $AccountNumber } else { '' }
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] Code={2} Account={3} RowCount={4} Attempt={5}' -f (Get-Date),$Level,$Code,$safeAccount,$RowCount,$Attempt
    $logPath = Join-Path $logDir 'sync.log'
    $lineBytes = [Text.Encoding]::UTF8.GetByteCount($line + [Environment]::NewLine)
    $currentBytes = if(Test-Path -LiteralPath $logPath) { (Get-Item -LiteralPath $logPath).Length } else { 0 }
    if($currentBytes -gt 0 -and ($currentBytes + $lineBytes) -gt 5MB) {
        for($index = 5; $index -ge 1; $index--) {
            $source = if($index -eq 1) { $logPath } else { "$logPath.$($index - 1)" }
            $target = "$logPath.$index"
            if(Test-Path -LiteralPath $source) {
                if(Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
                Move-Item -LiteralPath $source -Destination $target
            }
        }
    }
    Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
}

function Get-SyncFailureMessage {
    param([Parameter(Mandatory)][string]$Code)
    switch($Code) {
        'UntrustedOneDriveRoot' { return 'The configured OneDrive root is not currently trusted.' }
        'SourceUnavailable' { return 'The configured source CSV is unavailable.' }
        'SourceUnstable' { return 'The source CSV changed during validation.' }
        'SchemaValidationFailed' { return 'The source CSV did not pass schema validation.' }
        'PublicationFailed' { return 'The local publication could not be completed safely.' }
        default { return 'The configured account could not be synchronized.' }
    }
}

function Get-FileIdentity {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return [pscustomobject]@{
        Length = [int64]$item.Length
        LastWriteUtc = $item.LastWriteTimeUtc.ToString('o')
        Hash = $hash
    }
}

function Test-StableFile {
    param([Parameter(Mandatory)][string]$Path, [int]$Seconds = 2)
    $before = Get-FileIdentity -Path $Path
    if($Seconds -gt 0) { Start-Sleep -Seconds $Seconds }
    $after = Get-FileIdentity -Path $Path
    return $before.Length -eq $after.Length -and $before.LastWriteUtc -eq $after.LastWriteUtc -and $before.Hash -eq $after.Hash
}

function Write-AtomicText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [string]$TrustedOneDriveRoot = ''
    )
    $directory = Split-Path -Parent $Path
    if([string]::IsNullOrWhiteSpace($TrustedOneDriveRoot)) {
        if(-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
        $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
        $backup = "$Path.$([guid]::NewGuid().ToString('N')).bak"
        try {
            [IO.File]::WriteAllText($temporary, $Content, (New-Object System.Text.UTF8Encoding($false)))
            if(Test-Path -LiteralPath $Path) {
                [IO.File]::Replace($temporary, $Path, $backup, $true)
            } else {
                [IO.File]::Move($temporary, $Path)
            }
        } finally {
            if(Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
            if(Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
        }
        return
    }

    $directory = New-AmmarTradingTrustedDirectory -OneDriveRoot $TrustedOneDriveRoot -Path $directory -Description 'Publication directory'
    $Path = Assert-AmmarTradingTrustedDestinationPath -OneDriveRoot $TrustedOneDriveRoot -Path $Path -Description 'Publication file'
    $contentBytes = [Text.Encoding]::UTF8.GetBytes($Content)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $contentHash = [BitConverter]::ToString($sha256.ComputeHash($contentBytes)).Replace('-','') }
    finally { $sha256.Dispose() }
    $writeState = [pscustomobject]@{ Bytes=$contentBytes }
    [void](Publish-AmmarTradingTrustedFile -OneDriveRoot $TrustedOneDriveRoot -Destination $Path -Description 'Atomic text publication' -ExpectedLength $contentBytes.LongLength -ExpectedSha256 $contentHash -WriteState $writeState -ReplaceIfExists -WriteAction {
        param($Stream,$State)
        $bytes = [byte[]]$State.Bytes
        $Stream.Write($bytes,0,$bytes.Length)
    })
}

function Publish-AtomicFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string]$TrustedOneDriveRoot = '',
        [int64]$ExpectedLength = -1,
        [string]$ExpectedSha256 = '',
        [string]$ExpectedLastWriteUtc = ''
    )
    $directory = Split-Path -Parent $Destination
    if([string]::IsNullOrWhiteSpace($TrustedOneDriveRoot)) {
        if(-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
        $temporary = Join-Path $directory ("$([IO.Path]::GetFileName($Destination)).$([guid]::NewGuid().ToString('N')).tmp")
        $backup = Join-Path $directory ("$([IO.Path]::GetFileName($Destination)).$([guid]::NewGuid().ToString('N')).bak")
        try {
            [IO.File]::Copy($Source, $temporary, $true)
            if(Test-Path -LiteralPath $Destination) {
                [IO.File]::Replace($temporary, $Destination, $backup, $true)
            } else {
                [IO.File]::Move($temporary, $Destination)
            }
        } finally {
            if(Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
            if(Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
        }
        return
    }

    $directory = New-AmmarTradingTrustedDirectory -OneDriveRoot $TrustedOneDriveRoot -Path $directory -Description 'Publication directory'
    $expandedSource = [Environment]::ExpandEnvironmentVariables($Source.Trim())
    $expandedRoot = [Environment]::ExpandEnvironmentVariables($TrustedOneDriveRoot.Trim())
    $canonicalSourceCandidate = [IO.Path]::GetFullPath($expandedSource)
    $canonicalRootCandidate = [IO.Path]::GetFullPath($expandedRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $sourceBelowTrustedRoot = $canonicalSourceCandidate.StartsWith($canonicalRootCandidate + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
    if($sourceBelowTrustedRoot) {
        $Source = Assert-AmmarTradingTrustedDestinationPath -OneDriveRoot $TrustedOneDriveRoot -Path $canonicalSourceCandidate -Description 'CSV publication source file'
    } else {
        $Source = Resolve-AmmarTradingLocalPath -Path $canonicalSourceCandidate -PathType Leaf -Description 'CSV publication source file'
    }
    $Destination = Assert-AmmarTradingTrustedDestinationPath -OneDriveRoot $TrustedOneDriveRoot -Path $Destination -Description 'Published destination file'
    $sourceIdentity = Get-FileIdentity -Path $Source
    if($ExpectedLength -lt 0) { $ExpectedLength = [int64]$sourceIdentity.Length }
    if([string]::IsNullOrWhiteSpace($ExpectedSha256)) { $ExpectedSha256 = [string]$sourceIdentity.Hash }
    if([string]::IsNullOrWhiteSpace($ExpectedLastWriteUtc)) { $ExpectedLastWriteUtc = [string]$sourceIdentity.LastWriteUtc }
    if($sourceIdentity.Length -ne $ExpectedLength -or $sourceIdentity.Hash -ine $ExpectedSha256 -or $sourceIdentity.LastWriteUtc -cne $ExpectedLastWriteUtc) {
        throw 'Source changed before atomic CSV publication began.'
    }
    $writeState = [pscustomobject]@{
        Source = $Source
        ExpectedLength = [int64]$ExpectedLength
        ExpectedLastWriteUtc = $ExpectedLastWriteUtc
    }
    $additionalLockedPath = if($sourceBelowTrustedRoot) { @($Source) } else { @() }
    [void](Publish-AmmarTradingTrustedFile -OneDriveRoot $TrustedOneDriveRoot -Destination $Destination -Description 'Atomic CSV publication' -ExpectedLength $ExpectedLength -ExpectedSha256 $ExpectedSha256 -AdditionalLockedPath $additionalLockedPath -WriteState $writeState -ReplaceIfExists -WriteAction {
        param($Stream,$State)
        $sourceStream = [IO.FileStream]::new([string]$State.Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try { $sourceStream.CopyTo($Stream) }
        finally { $sourceStream.Dispose() }
        $sourceInfo = [IO.FileInfo]::new([string]$State.Source)
        $sourceInfo.Refresh()
        if([int64]$sourceInfo.Length -ne [int64]$State.ExpectedLength -or
           $sourceInfo.LastWriteTimeUtc.ToString('o') -cne [string]$State.ExpectedLastWriteUtc) {
            throw 'Source changed while atomic CSV bytes were being copied.'
        }
    })
}

function Get-AmmarTradingDestinationPath {
    param(
        [Parameter(Mandatory)][string]$OneDriveRoot,
        [Parameter(Mandatory)][string]$AccountNumber,
        [string]$VpsId
    )
    $accountPath = Join-Path ("Account_{0}" -f $AccountNumber) 'Baskets.csv'
    $relative = if([string]::IsNullOrWhiteSpace($VpsId)) { Join-Path 'AmarTrading' $accountPath } else { Join-Path (Join-Path 'AmarTrading' ("VPS_{0}" -f $VpsId)) $accountPath }
    Join-Path $OneDriveRoot $relative
}

function Get-LastRunState {
    param([string]$RuntimeRoot = $ScriptRoot)
    $path = Join-Path $RuntimeRoot 'state\last-run.json'
    if(-not (Test-Path -LiteralPath $path)) { return @{} }
    $content = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    if([string]::IsNullOrWhiteSpace($content)) { return @{} }
    $parsed = ConvertFrom-Json -InputObject $content
    $accountState = if($parsed.PSObject.Properties['Accounts']) { $parsed.Accounts } else { $parsed }
    $state = @{}
    foreach($property in $accountState.PSObject.Properties) { $state[$property.Name] = $property.Value }
    return $state
}

function Save-LastRunSummary {
    param(
        [hashtable]$State,
        [object[]]$Results,
        [string]$StartedUtc,
        [string]$RuntimeRoot = $ScriptRoot
    )
    $summary = [ordered]@{
        StartedUtc = $StartedUtc
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        OverallStatus = if(@($Results | Where-Object Status -eq 'Error').Count -gt 0) { 'Error' } else { 'Success' }
        Accounts = $State
        Results = @($Results)
    }
    Write-AtomicText -Path (Join-Path $RuntimeRoot 'state\last-run.json') -Content ($summary | ConvertTo-Json -Depth 8)
}

function Write-FatalSyncError {
    param([Parameter(Mandatory)][ValidateSet('FatalSyncFailure')][string]$Code, [string]$RuntimeRoot = $ScriptRoot)
    $line = '{0:yyyy-MM-dd HH:mm:ss} [FATAL] Code={1}' -f (Get-Date), $Code
    foreach($path in @((Join-Path $RuntimeRoot 'task-error.log'), (Join-Path $env:TEMP 'MoneyMachineCsvSync-task-error.log'))) {
        try { Add-Content -LiteralPath $path -Value $line -Encoding utf8 } catch { }
    }
}

function Invoke-MoneyMachineCsvSync {
    [CmdletBinding()]
    param(
        [string]$ConfigPath = (Join-Path $PSScriptRoot 'accounts.csv'),
        [switch]$StartupCatchup,
        [int]$StableCheckSeconds = 2,
        [int]$MaxRetries = 3,
        [int]$MutexWaitMilliseconds = 30000,
        [string]$RuntimeRoot,
        [string[]]$AccountNumbers
    )

    if([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $ScriptRoot 'accounts.csv' }
    if([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ScriptRoot }
    if($StableCheckSeconds -lt 0) { throw 'StableCheckSeconds must be zero or greater.' }
    if($MaxRetries -lt 1) { throw 'MaxRetries must be at least one.' }
    if($MutexWaitMilliseconds -lt 0) { throw 'MutexWaitMilliseconds must be zero or greater.' }
    if(-not (Test-Path -LiteralPath $ConfigPath)) { throw 'The sync configuration is unavailable.' }

    $hasAccountFilter = $PSBoundParameters.ContainsKey('AccountNumbers')
    $accountFilter = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    if($hasAccountFilter) {
        foreach($accountNumberValue in @($AccountNumbers)) {
            $accountNumber = ([string]$accountNumberValue).Trim()
            if($accountNumber -notmatch '^\d{4,20}$') { throw 'AccountNumbers contains an invalid MT4 account number.' }
            if(-not $accountFilter.Add($accountNumber)) { throw "AccountNumbers contains duplicate MT4 account '$accountNumber'." }
        }
    }

    $startedUtc = [DateTime]::UtcNow.ToString('o')
    $mutex = New-Object System.Threading.Mutex($false, 'Global\MoneyMachineCsvSync')
    $hasLock = $false
    try {
        $hasLock = $mutex.WaitOne($MutexWaitMilliseconds)
        if(-not $hasLock) { throw 'Timed out waiting for the MoneyMachineCsvSync mutex.' }

        $today = (Get-Date).ToString('yyyy-MM-dd')
        $identity = Get-AmmarTradingVpsIdentity -RuntimeRoot $RuntimeRoot
        $state = Get-LastRunState -RuntimeRoot $RuntimeRoot
        $results = [System.Collections.Generic.List[object]]::new()
        foreach($account in @(Import-Csv -LiteralPath $ConfigPath -ErrorAction Stop)) {
            $expectedLogin = ([string]$account.ExpectedMT4Login).Trim()
            if($hasAccountFilter -and -not $accountFilter.Contains($expectedLogin)) { continue }
            if($expectedLogin -notmatch '^\d{4,20}$') {
                $results.Add([pscustomobject]@{ AccountNumber=''; Status='Error'; FailureCode='MissingConfiguration'; Message='The account configuration is incomplete.' })
                continue
            }
            $enabled = ([string]$account.Enabled).Trim().ToLowerInvariant() -in @('true','1','yes','y')
            if(-not $enabled) {
                $results.Add([pscustomobject]@{ AccountNumber=$expectedLogin; Status='Skipped'; FailureCode=''; Message='This account is disabled.' })
                continue
            }
            $sourceCsv = [Environment]::ExpandEnvironmentVariables(([string]$account.SourceCsv).Trim())
            $oneDriveRoot = [Environment]::ExpandEnvironmentVariables(([string]$account.OneDriveRoot).Trim())
            $vpsId = if($account.PSObject.Properties['VpsId']) { ([string]$account.VpsId).Trim() } else { '' }
            $vpsName = if($account.PSObject.Properties['VpsName']) { ([string]$account.VpsName).Trim() } else { '' }
            if($vpsId -and $vpsId -cne [string]$identity.VpsId) { throw 'The configured account belongs to a different VPS identity.' }
            if([string]::IsNullOrWhiteSpace($vpsId)) { $vpsId = '' }
            if([string]::IsNullOrWhiteSpace($expectedLogin) -or [string]::IsNullOrWhiteSpace($sourceCsv) -or [string]::IsNullOrWhiteSpace($oneDriveRoot)) {
                $results.Add([pscustomobject]@{ AccountNumber=$expectedLogin; Status='Error'; FailureCode='MissingConfiguration'; Message='The account configuration is incomplete.' })
                continue
            }
            $stateKey = '{0}|{1}' -f $(if($vpsId){$vpsId}else{'legacy-unassigned'}),$expectedLogin
            if($StartupCatchup -and $state.ContainsKey($stateKey) -and [string]$state[$stateKey].Status -eq 'Success' -and [string]$state[$stateKey].SuccessDate -eq $today) {
                $results.Add([pscustomobject]@{ AccountNumber=$expectedLogin; Status='Skipped'; FailureCode=''; Message='This account was already published today.' })
                continue
            }

            $published = $false
            $failureCode = 'PublicationFailed'
            $result = $null
            $lastAttempt = 0
            for($attempt = 1; $attempt -le $MaxRetries -and -not $published; $attempt++) {
                $lastAttempt = $attempt
                try {
                    $failureCode = 'UntrustedOneDriveRoot'
                    $oneDriveRoot = Resolve-AmmarTradingOneDriveRoot -Path $oneDriveRoot -RequireWritable
                    $failureCode = 'SourceUnavailable'
                    $sourceCsv = Resolve-AmmarTradingLocalPath -Path $sourceCsv -PathType Leaf -Description 'Source CSV'
                    $failureCode = 'SourceUnstable'
                    if(-not (Test-StableFile -Path $sourceCsv -Seconds $StableCheckSeconds)) { throw 'Source changed during stable-file check.' }
                    $sourceBefore = Get-FileIdentity -Path $sourceCsv
                    $failureCode = 'SchemaValidationFailed'
                    $validation = Read-MoneyMachineBasketsCsv -Path $sourceCsv -ExpectedLogin $expectedLogin
                    $failureCode = 'PublicationFailed'
                    $destination = Get-AmmarTradingDestinationPath -OneDriveRoot $oneDriveRoot -AccountNumber $expectedLogin -VpsId $vpsId
                    $destinationDir = Split-Path -Parent $destination
                    $destinationDir = New-AmmarTradingTrustedDirectory -OneDriveRoot $oneDriveRoot -Path $destinationDir -Description 'Account publication directory'
                    if($vpsId) {
                        $vpsDirectory = Split-Path -Parent $destinationDir
                        [void](New-AmmarTradingTrustedDirectory -OneDriveRoot $oneDriveRoot -Path $vpsDirectory -Description 'VPS publication directory')
                        $manifestPath = Assert-AmmarTradingTrustedDestinationPath -OneDriveRoot $oneDriveRoot -Path (Join-Path $vpsDirectory 'Vps.json') -Description 'VPS identity manifest'
                        $manifest = [ordered]@{ IdentitySchemaVersion = 1; VpsId = $vpsId; VpsName = [string]$vpsName; Accounts = @(); UpdatedUtc = [DateTime]::UtcNow.ToString('o') }
                        foreach($configured in @(Import-Csv -LiteralPath $ConfigPath -ErrorAction Stop)) { $configuredId = if($configured.PSObject.Properties['VpsId']) { ([string]$configured.VpsId).Trim() } else { '' }; if($configuredId -eq $vpsId) { $manifest.Accounts += ([string]$configured.ExpectedMT4Login).Trim() } }
                        Write-AtomicText -Path $manifestPath -Content ($manifest | ConvertTo-Json -Depth 5) -TrustedOneDriveRoot $oneDriveRoot
                    }
                    $destination = Assert-AmmarTradingTrustedDestinationPath -OneDriveRoot $oneDriveRoot -Path $destination -Description 'Basket destination file'
                    Publish-AtomicFile -Source $sourceCsv -Destination $destination -TrustedOneDriveRoot $oneDriveRoot -ExpectedLength $sourceBefore.Length -ExpectedSha256 $sourceBefore.Hash -ExpectedLastWriteUtc $sourceBefore.LastWriteUtc
                    $destinationIdentity = @(Invoke-AmmarTradingTrustedPathOperation -OneDriveRoot $oneDriveRoot -Path @($destination) -Description 'Published basket verification' -Action {
                        Get-FileIdentity -Path $destination
                    })[0]
                    if($destinationIdentity.Hash -ne $sourceBefore.Hash) { throw 'Published destination hash does not match the source hash.' }
                    $publicationUtc = [DateTime]::UtcNow.ToString('o')
                    $heartbeat = [ordered]@{
                        VpsId = if($vpsId) { $vpsId } else { 'legacy-unassigned' }
                        VpsName = [string]$vpsName
                        AccountNumber = $expectedLogin
                        Status = 'Success'
                        RowCount = $validation.RowCount
                        SourceHash = $sourceBefore.Hash
                        DestinationHash = $destinationIdentity.Hash
                        SourceLastWriteUtc = $sourceBefore.LastWriteUtc
                        PublishedUtc = $publicationUtc
                        CloudDeliveryVerified = $false
                    }
                    $heartbeatPath = Assert-AmmarTradingTrustedDestinationPath -OneDriveRoot $oneDriveRoot -Path (Join-Path $destinationDir 'SyncStatus.json') -Description 'Sync heartbeat file'
                    Write-AtomicText -Path $heartbeatPath -Content ($heartbeat | ConvertTo-Json -Depth 5) -TrustedOneDriveRoot $oneDriveRoot
                    $result = [pscustomobject]@{ AccountNumber=$expectedLogin; Status='Success'; FailureCode=''; Message='Published the latest cumulative Baskets.csv.'; RowCount=$validation.RowCount; SourceHash=$sourceBefore.Hash; DestinationHash=$destinationIdentity.Hash; PublishedUtc=$publicationUtc }
                    $published = $true
                } catch {
                    if($attempt -lt $MaxRetries) { Start-Sleep -Seconds 1 }
                }
            }
            if($published) {
                $state[('{0}|{1}' -f $(if($vpsId){$vpsId}else{'legacy-unassigned'}),$expectedLogin)] = [ordered]@{ Status='Success'; SuccessDate=$today; RowCount=$result.RowCount; SourceHash=$result.SourceHash; DestinationHash=$result.DestinationHash; PublishedUtc=$result.PublishedUtc }
                $results.Add($result)
                Write-SyncLog -Level 'INFO' -Code Published -AccountNumber $expectedLogin -RowCount $result.RowCount -Attempt $lastAttempt -RuntimeRoot $RuntimeRoot
            } else {
                $result = [pscustomobject]@{ AccountNumber=$expectedLogin; Status='Error'; FailureCode=$failureCode; Message=(Get-SyncFailureMessage -Code $failureCode) }
                $state[$stateKey] = [ordered]@{ Status='Error'; SuccessDate=$today; FailureCode=$failureCode }
                $results.Add($result)
                Write-SyncLog -Level 'ERROR' -Code $failureCode -AccountNumber $expectedLogin -RowCount -1 -Attempt $lastAttempt -RuntimeRoot $RuntimeRoot
            }
        }
        Save-LastRunSummary -State $state -Results @($results) -StartedUtc $startedUtc -RuntimeRoot $RuntimeRoot
        return $results
    } finally {
        if($hasLock) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

if(-not $AsLibrary) {
    try {
        $syncParameters = @{
            ConfigPath = $ConfigPath
            StartupCatchup = $StartupCatchup
            StableCheckSeconds = $StableCheckSeconds
            MaxRetries = $MaxRetries
            MutexWaitMilliseconds = $MutexWaitMilliseconds
            RuntimeRoot = $RuntimeRoot
        }
        if($PSBoundParameters.ContainsKey('AccountNumbers')) { $syncParameters.AccountNumbers = $AccountNumbers }
        $runResults = @(Invoke-MoneyMachineCsvSync @syncParameters)
        $runResults | Format-Table -AutoSize
        if(@($runResults | Where-Object { $_.Status -eq 'Error' }).Count -gt 0) { exit 1 }
    } catch {
        Write-FatalSyncError -Code FatalSyncFailure -RuntimeRoot $RuntimeRoot
        throw
    }
}
