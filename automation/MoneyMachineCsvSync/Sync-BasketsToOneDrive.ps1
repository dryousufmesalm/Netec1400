[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'accounts.csv'),
    [switch]$StartupCatchup,
    [switch]$AsLibrary,
    [int]$StableCheckSeconds = 2,
    [int]$MaxRetries = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-SyncLog {
    param([string]$Level, [string]$Message)
    $logDir = Join-Path $PSScriptRoot 'logs'
    if(-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath (Join-Path $logDir 'sync.log') -Value $line -Encoding utf8
}

function Test-StableFile {
    param([Parameter(Mandatory)][string]$Path, [int]$Seconds = 2)
    $before = Get-Item -LiteralPath $Path -ErrorAction Stop
    if($Seconds -gt 0) { Start-Sleep -Seconds $Seconds }
    $after = Get-Item -LiteralPath $Path -ErrorAction Stop
    return $before.Length -eq $after.Length -and $before.LastWriteTimeUtc -eq $after.LastWriteTimeUtc
}

function Test-BasketsCsvHeader {
    param([Parameter(Mandatory)][string]$Path)
    $header = Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop
    if([string]::IsNullOrWhiteSpace($header)) { throw 'CSV header is empty.' }
    $columns = @($header.TrimStart([char]0xFEFF).Split(','))
    foreach($required in 'AccountNumber','BasketID','ClosePL','CsvSchemaVersion') {
        if($columns -notcontains $required) { throw "CSV is missing required column '$required'." }
    }
}

function Get-BasketsCsvLogin {
    param([Parameter(Mandatory)][string]$Path)
    Test-BasketsCsvHeader -Path $Path
    $first = @(Import-Csv -LiteralPath $Path -ErrorAction Stop | Select-Object -First 1)[0]
    if($null -eq $first -or [string]::IsNullOrWhiteSpace([string]$first.AccountNumber)) {
        throw 'CSV contains no basket row with AccountNumber; it cannot be assigned safely.'
    }
    return ([string]$first.AccountNumber).Trim()
}

function Get-SuccessState {
    $stateDir = Join-Path $PSScriptRoot 'state'
    $statePath = Join-Path $stateDir 'last-success.csv'
    if(-not (Test-Path -LiteralPath $statePath)) { return @{} }
    $state = @{}
    foreach($row in @(Import-Csv -LiteralPath $statePath)) {
        if($row.AccountNumber -and $row.SuccessDate) { $state[[string]$row.AccountNumber] = [string]$row.SuccessDate }
    }
    return $state
}

function Save-SuccessState {
    param([hashtable]$State)
    $stateDir = Join-Path $PSScriptRoot 'state'
    if(-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $rows = foreach($account in @($State.Keys | Sort-Object)) {
        [pscustomobject]@{ AccountNumber = $account; SuccessDate = $State[$account] }
    }
    $rows | Export-Csv -LiteralPath (Join-Path $stateDir 'last-success.csv') -NoTypeInformation -Encoding utf8
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

    $today = (Get-Date).ToString('yyyy-MM-dd')
    $successState = Get-SuccessState
    $results = [System.Collections.Generic.List[object]]::new()
    $accounts = @(Import-Csv -LiteralPath $ConfigPath)
    foreach($account in $accounts) {
        $expectedLogin = ([string]$account.ExpectedMT4Login).Trim()
        $enabled = ([string]$account.Enabled).Trim().ToLowerInvariant() -in @('true','1','yes','y')
        if(-not $enabled) {
            $results.Add([pscustomobject]@{ AccountNumber=$expectedLogin; Status='Skipped'; Message='Disabled in accounts.csv' })
            continue
        }
        if([string]::IsNullOrWhiteSpace($expectedLogin) -or [string]::IsNullOrWhiteSpace([string]$account.SourceCsv) -or [string]::IsNullOrWhiteSpace([string]$account.OneDriveRoot)) {
            $results.Add([pscustomobject]@{ AccountNumber=$expectedLogin; Status='Skipped'; Message='Missing required configuration value' })
            Write-SyncLog 'WARN' "Skipped account '$expectedLogin': missing configuration value."
            continue
        }
        if($StartupCatchup -and $successState[$expectedLogin] -eq $today) {
            $results.Add([pscustomobject]@{ AccountNumber=$expectedLogin; Status='Skipped'; Message='Already copied successfully today' })
            continue
        }

        $sourceCsv = [Environment]::ExpandEnvironmentVariables(([string]$account.SourceCsv).Trim())
        $oneDriveRoot = [Environment]::ExpandEnvironmentVariables(([string]$account.OneDriveRoot).Trim())
        if(-not (Test-Path -LiteralPath $sourceCsv)) {
            $results.Add([pscustomobject]@{ AccountNumber=$expectedLogin; Status='Skipped'; Message="Source CSV not found: $sourceCsv" })
            Write-SyncLog 'WARN' "Skipped account '$expectedLogin': source CSV not found."
            continue
        }

        $copied = $false
        $message = ''
        for($attempt = 1; $attempt -le $MaxRetries -and -not $copied; $attempt++) {
            try {
                if(-not (Test-StableFile -Path $sourceCsv -Seconds $StableCheckSeconds)) {
                    $message = 'Source changed during stable-file check.'
                    continue
                }
                $actualLogin = Get-BasketsCsvLogin -Path $sourceCsv
                if($actualLogin -ne $expectedLogin) {
                    $message = "CSV AccountNumber '$actualLogin' does not match ExpectedMT4Login '$expectedLogin'."
                    break
                }

                $destinationDir = Join-Path $oneDriveRoot (Join-Path 'MoneyMachine' ("Account_{0}" -f $actualLogin))
                if(-not (Test-Path -LiteralPath $destinationDir)) { New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null }
                $destination = Join-Path $destinationDir 'Baskets.csv'
                $temporary = Join-Path $destinationDir ("Baskets.csv.{0}.tmp" -f [guid]::NewGuid().ToString('N'))
                try {
                    Copy-Item -LiteralPath $sourceCsv -Destination $temporary -Force -ErrorAction Stop
                    if(-not (Test-StableFile -Path $sourceCsv -Seconds 0)) { throw 'Source changed while temporary copy was being made.' }
                    Test-BasketsCsvHeader -Path $temporary
                    [IO.File]::Copy($temporary, $destination, $true)
                    $copied = $true
                }
                finally {
                    if(Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
                }
            }
            catch {
                $message = $_.Exception.Message
                if($attempt -lt $MaxRetries) { Start-Sleep -Seconds 1 }
            }
        }

        if($copied) {
            $successState[$expectedLogin] = $today
            $results.Add([pscustomobject]@{ AccountNumber=$expectedLogin; Status='Success'; Message='Copied latest cumulative Baskets.csv' })
            Write-SyncLog 'INFO' "Copied account '$expectedLogin' successfully."
        }
        else {
            $status = if($message -match 'does not match') { 'Skipped' } else { 'Error' }
            $results.Add([pscustomobject]@{ AccountNumber=$expectedLogin; Status=$status; Message=$message })
            Write-SyncLog 'WARN' "Account '$expectedLogin' not copied: $message"
        }
    }
    Save-SuccessState -State $successState
    return $results
}

if(-not $AsLibrary) {
    Invoke-MoneyMachineCsvSync -ConfigPath $ConfigPath -StartupCatchup:$StartupCatchup -StableCheckSeconds $StableCheckSeconds -MaxRetries $MaxRetries |
        Format-Table -AutoSize
}
