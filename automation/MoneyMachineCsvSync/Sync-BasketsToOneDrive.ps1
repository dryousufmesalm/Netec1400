[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$StartupCatchup,
    [switch]$AsLibrary,
    [int]$StableCheckSeconds = 2,
    [int]$MaxRetries = 3,
    [int]$MutexWaitMilliseconds = 30000,
    [string]$RuntimeRoot
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

function Write-SyncLog {
    param([string]$Level, [string]$Message, [string]$RuntimeRoot = $ScriptRoot)
    $logDir = Join-Path $RuntimeRoot 'logs'
    if(-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
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
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $directory = Split-Path -Parent $Path
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
}

function Publish-AtomicFile {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    $directory = Split-Path -Parent $Destination
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
    param([Parameter(Mandatory)][string]$Message, [string]$RuntimeRoot = $ScriptRoot)
    $line = '{0:yyyy-MM-dd HH:mm:ss} [FATAL] {1}' -f (Get-Date), $Message
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
        [string]$RuntimeRoot
    )

    if([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $ScriptRoot 'accounts.csv' }
    if([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ScriptRoot }
    if($StableCheckSeconds -lt 0) { throw 'StableCheckSeconds must be zero or greater.' }
    if($MaxRetries -lt 1) { throw 'MaxRetries must be at least one.' }
    if($MutexWaitMilliseconds -lt 0) { throw 'MutexWaitMilliseconds must be zero or greater.' }
    if(-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuration file not found: $ConfigPath" }

    $startedUtc = [DateTime]::UtcNow.ToString('o')
    $mutex = New-Object System.Threading.Mutex($false, 'Global\MoneyMachineCsvSync')
    $hasLock = $false
    try {
        $hasLock = $mutex.WaitOne($MutexWaitMilliseconds)
        if(-not $hasLock) { throw 'Timed out waiting for the MoneyMachineCsvSync mutex.' }

        $today = (Get-Date).ToString('yyyy-MM-dd')
        $state = Get-LastRunState -RuntimeRoot $RuntimeRoot
        $results = [System.Collections.Generic.List[object]]::new()
        foreach($account in @(Import-Csv -LiteralPath $ConfigPath -ErrorAction Stop)) {
            $expectedLogin = ([string]$account.ExpectedMT4Login).Trim()
            $enabled = ([string]$account.Enabled).Trim().ToLowerInvariant() -in @('true','1','yes','y')
            if(-not $enabled) {
                $results.Add([pscustomobject]@{ AccountNumber=$expectedLogin; Status='Skipped'; Message='Disabled in accounts.csv' })
                continue
            }
            $sourceCsv = [Environment]::ExpandEnvironmentVariables(([string]$account.SourceCsv).Trim())
            $oneDriveRoot = [Environment]::ExpandEnvironmentVariables(([string]$account.OneDriveRoot).Trim())
            if([string]::IsNullOrWhiteSpace($expectedLogin) -or [string]::IsNullOrWhiteSpace($sourceCsv) -or [string]::IsNullOrWhiteSpace($oneDriveRoot)) {
                $results.Add([pscustomobject]@{ AccountNumber=$expectedLogin; Status='Error'; Message='Missing required configuration value' })
                continue
            }
            if($StartupCatchup -and $state.ContainsKey($expectedLogin) -and [string]$state[$expectedLogin].Status -eq 'Success' -and [string]$state[$expectedLogin].SuccessDate -eq $today) {
                $results.Add([pscustomobject]@{ AccountNumber=$expectedLogin; Status='Skipped'; Message='Already copied successfully today' })
                continue
            }

            $published = $false
            $message = ''
            $result = $null
            for($attempt = 1; $attempt -le $MaxRetries -and -not $published; $attempt++) {
                try {
                    if(-not (Test-Path -LiteralPath $sourceCsv)) { throw "Source CSV not found: $sourceCsv" }
                    if(-not (Test-StableFile -Path $sourceCsv -Seconds $StableCheckSeconds)) { throw 'Source changed during stable-file check.' }
                    $sourceBefore = Get-FileIdentity -Path $sourceCsv
                    $validation = Read-MoneyMachineBasketsCsv -Path $sourceCsv -ExpectedLogin $expectedLogin
                    $destinationDir = Join-Path $oneDriveRoot (Join-Path 'MoneyMachine' ("Account_{0}" -f $expectedLogin))
                    $destination = Join-Path $destinationDir 'Baskets.csv'
                    $temporary = Join-Path $destinationDir ("Baskets.csv.$([guid]::NewGuid().ToString('N')).source.tmp")
                    try {
                        if(-not (Test-Path -LiteralPath $destinationDir)) { New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null }
                        [IO.File]::Copy($sourceCsv, $temporary, $true)
                        $sourceAfter = Get-FileIdentity -Path $sourceCsv
                        $temporaryIdentity = Get-FileIdentity -Path $temporary
                        if($sourceBefore.Hash -ne $sourceAfter.Hash -or $sourceBefore.Length -ne $sourceAfter.Length -or $sourceBefore.LastWriteUtc -ne $sourceAfter.LastWriteUtc) { throw 'Source changed while temporary copy was being made.' }
                        if($temporaryIdentity.Hash -ne $sourceBefore.Hash) { throw 'Temporary copy hash does not match the source hash.' }
                        $temporaryValidation = Read-MoneyMachineBasketsCsv -Path $temporary -ExpectedLogin $expectedLogin
                        Publish-AtomicFile -Source $temporary -Destination $destination
                        $destinationIdentity = Get-FileIdentity -Path $destination
                        if($destinationIdentity.Hash -ne $sourceBefore.Hash) { throw 'Published destination hash does not match the source hash.' }
                        $publicationUtc = [DateTime]::UtcNow.ToString('o')
                        $heartbeat = [ordered]@{
                            AccountNumber = $expectedLogin
                            Status = 'Success'
                            RowCount = $temporaryValidation.RowCount
                            SourceHash = $sourceBefore.Hash
                            DestinationHash = $destinationIdentity.Hash
                            SourceLastWriteUtc = $sourceBefore.LastWriteUtc
                            PublishedUtc = $publicationUtc
                            CloudDeliveryVerified = $false
                        }
                        Write-AtomicText -Path (Join-Path $destinationDir 'SyncStatus.json') -Content ($heartbeat | ConvertTo-Json -Depth 5)
                        $result = [pscustomobject]@{ AccountNumber=$expectedLogin; Status='Success'; Message='Published latest cumulative Baskets.csv'; RowCount=$temporaryValidation.RowCount; SourceHash=$sourceBefore.Hash; DestinationHash=$destinationIdentity.Hash; PublishedUtc=$publicationUtc }
                        $published = $true
                    } finally {
                        if(Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
                    }
                } catch {
                    $message = $_.Exception.Message
                    if($attempt -lt $MaxRetries) { Start-Sleep -Seconds 1 }
                }
            }
            if($published) {
                $state[$expectedLogin] = [ordered]@{ Status='Success'; SuccessDate=$today; RowCount=$result.RowCount; SourceHash=$result.SourceHash; DestinationHash=$result.DestinationHash; PublishedUtc=$result.PublishedUtc }
                $results.Add($result)
                Write-SyncLog -Level 'INFO' -Message "Published account '$expectedLogin' successfully. Rows=$($result.RowCount)." -RuntimeRoot $RuntimeRoot
            } else {
                $result = [pscustomobject]@{ AccountNumber=$expectedLogin; Status='Error'; Message=$message }
                $state[$expectedLogin] = [ordered]@{ Status='Error'; SuccessDate=$today; Message=$message }
                $results.Add($result)
                Write-SyncLog -Level 'ERROR' -Message "Account '$expectedLogin' failed: $message" -RuntimeRoot $RuntimeRoot
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
        $runResults = @(Invoke-MoneyMachineCsvSync -ConfigPath $ConfigPath -StartupCatchup:$StartupCatchup -StableCheckSeconds $StableCheckSeconds -MaxRetries $MaxRetries -MutexWaitMilliseconds $MutexWaitMilliseconds -RuntimeRoot $RuntimeRoot)
        $runResults | Format-Table -AutoSize
        if(@($runResults | Where-Object { $_.Status -eq 'Error' }).Count -gt 0) { exit 1 }
    } catch {
        Write-FatalSyncError -Message $_.Exception.ToString() -RuntimeRoot $RuntimeRoot
        throw
    }
}
