[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$StartupCatchup,
    [switch]$AsLibrary,
    [int]$StableCheckSeconds = 2,
    [int]$MaxRetries = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $PSCommandPath
if([string]::IsNullOrWhiteSpace($ScriptRoot)) { throw 'Could not resolve the sync script directory.' }
if([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $ScriptRoot 'accounts.csv' }

$SchemaV3Columns = @(
    'AccountNumber','BrokerName','BasketID','Symbol','SymbolNormalized','Timeframe','StartTime','EndTime','DurationSeconds',
    'Direction','OrdersCount','TotalLots','FixedLots','MaxOrdersConcurrent','MaxTotalLots','MaxFloatingDrawdownAbs','MaxFloatingProfit',
    'ClosePL','CloseReason','OutcomeClass','SpreadAtEntry','EquityAtEntry','HeadroomAtEntry','MinHeadroom','TimesNearKill',
    'ExposureBlocks','PipsStep','TakeProfit','KillEquityLevel','MaxOrdersInBasket','MaxTotalLotsInBasket','EquityAtExit','BalanceAfter',
    'TradeDate','RunID','RunStartTime','RunStartBalance','EAName','EAVersion','Magic','PointsPerPip','Tral','TralStart','MaxSpread',
    'TimeStart','TimeEnd','OpenTime','NewBasketDelaySeconds','SpeedEA','UseBasketTrailingTP','TrailingStart','TrailingStep',
    'KillSwitchEnable','KillCooldownMinutes','RegimeEnable','RegimeAction','RegimeADXPeriod','RegimeADXLevel','RegimeADXBars',
    'RegimeRangeBars','RegimeRecoveryBars','EnableTradingDaysFilter','TradeMonday','TradeTuesday','TradeWednesday','TradeThursday',
    'TradeFriday','EnableRecoveryStepUp','RecoveryWaitMinutes','RecoveryMaxTotalLotsInBasket','CsvSchemaVersion'
)

function Write-SyncLog {
    param([string]$Level, [string]$Message)
    $logDir = Join-Path $ScriptRoot 'logs'
    if(-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath (Join-Path $logDir 'sync.log') -Value $line -Encoding utf8
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

function Get-CsvHeader {
    param([Parameter(Mandatory)][string]$Path)
    $line = Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop
    if([string]::IsNullOrWhiteSpace($line)) { throw 'CSV header is empty.' }
    return @($line.TrimStart([char]0xFEFF).Split(',') | ForEach-Object { $_.Trim().Trim('"') })
}

function Read-AndValidateBasketsCsv {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedLogin
    )
    $header = @(Get-CsvHeader -Path $Path)
    if($header.Count -ne $SchemaV3Columns.Count) { throw "CSV header has $($header.Count) columns; expected $($SchemaV3Columns.Count)." }
    for($index = 0; $index -lt $SchemaV3Columns.Count; $index++) {
        if($header[$index] -cne $SchemaV3Columns[$index]) { throw "CSV header column $($index + 1) is '$($header[$index])'; expected '$($SchemaV3Columns[$index])'." }
    }

    $rows = @(Import-Csv -LiteralPath $Path -ErrorAction Stop)
    foreach($row in $rows) {
        if(@($row.PSObject.Properties).Count -ne $SchemaV3Columns.Count) { throw 'CSV row field count does not match the schema-v3 contract.' }
        if([string]::IsNullOrWhiteSpace([string]$row.AccountNumber)) { throw 'CSV row is missing AccountNumber.' }
        if(([string]$row.AccountNumber).Trim() -ne $ExpectedLogin) { throw "CSV AccountNumber '$($row.AccountNumber)' does not match ExpectedMT4Login '$ExpectedLogin'." }
        if(([string]$row.CsvSchemaVersion).Trim() -ne '3') { throw 'CSV row CsvSchemaVersion must be 3.' }
        if([string]::IsNullOrWhiteSpace([string]$row.BasketID) -or [string]::IsNullOrWhiteSpace([string]$row.RunID)) { throw 'CSV row is missing BasketID or RunID.' }
    }
    return [pscustomobject]@{ Rows = $rows; RowCount = $rows.Count; Header = ($header -join ',') }
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
    $path = Join-Path $ScriptRoot 'state\last-run.json'
    if(-not (Test-Path -LiteralPath $path)) { return @{} }
    $content = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    if([string]::IsNullOrWhiteSpace($content)) { return @{} }
    $parsed = ConvertFrom-Json -InputObject $content
    $state = @{}
    foreach($property in $parsed.PSObject.Properties) { $state[$property.Name] = $property.Value }
    return $state
}

function Save-LastRunState {
    param([hashtable]$State)
    Write-AtomicText -Path (Join-Path $ScriptRoot 'state\last-run.json') -Content ($State | ConvertTo-Json -Depth 8)
}

function Write-FatalSyncError {
    param([Parameter(Mandatory)][string]$Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss} [FATAL] {1}' -f (Get-Date), $Message
    foreach($path in @((Join-Path $ScriptRoot 'task-error.log'), (Join-Path $env:TEMP 'MoneyMachineCsvSync-task-error.log'))) {
        try { Add-Content -LiteralPath $path -Value $line -Encoding utf8 } catch { }
    }
}

function Invoke-MoneyMachineCsvSync {
    [CmdletBinding()]
    param(
        [string]$ConfigPath = (Join-Path $PSScriptRoot 'accounts.csv'),
        [switch]$StartupCatchup,
        [int]$StableCheckSeconds = 2,
        [int]$MaxRetries = 3
    )

    if($StableCheckSeconds -lt 0) { throw 'StableCheckSeconds must be zero or greater.' }
    if($MaxRetries -lt 1) { throw 'MaxRetries must be at least one.' }
    if(-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuration file not found: $ConfigPath" }

    $mutex = New-Object System.Threading.Mutex($false, 'Global\MoneyMachineCsvSync')
    $hasLock = $false
    try {
        $hasLock = $mutex.WaitOne(30000)
        if(-not $hasLock) { throw 'Timed out waiting for the MoneyMachineCsvSync mutex.' }

        $today = (Get-Date).ToString('yyyy-MM-dd')
        $state = Get-LastRunState
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
                    $validation = Read-AndValidateBasketsCsv -Path $sourceCsv -ExpectedLogin $expectedLogin
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
                        $temporaryValidation = Read-AndValidateBasketsCsv -Path $temporary -ExpectedLogin $expectedLogin
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
                Write-SyncLog 'INFO' "Published account '$expectedLogin' successfully. Rows=$($result.RowCount)."
            } else {
                $result = [pscustomobject]@{ AccountNumber=$expectedLogin; Status='Error'; Message=$message }
                $state[$expectedLogin] = [ordered]@{ Status='Error'; SuccessDate=$today; Message=$message }
                $results.Add($result)
                Write-SyncLog 'ERROR' "Account '$expectedLogin' failed: $message"
            }
        }
        Save-LastRunState -State $state
        return $results
    } finally {
        if($hasLock) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

if(-not $AsLibrary) {
    try {
        $runResults = @(Invoke-MoneyMachineCsvSync -ConfigPath $ConfigPath -StartupCatchup:$StartupCatchup -StableCheckSeconds $StableCheckSeconds -MaxRetries $MaxRetries)
        $runResults | Format-Table -AutoSize
        if(@($runResults | Where-Object { $_.Status -eq 'Error' }).Count -gt 0) { exit 1 }
    } catch {
        Write-FatalSyncError -Message $_.Exception.ToString()
        throw
    }
}
