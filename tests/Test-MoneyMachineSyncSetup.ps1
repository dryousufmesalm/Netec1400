[CmdletBinding()]
param(
    [string]$ModulePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if([string]::IsNullOrWhiteSpace($ModulePath)) {
    $ModulePath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1'
}
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("MoneyMachineSyncSetupTest_" + [guid]::NewGuid().ToString('N'))

function Assert-ThrowsLike {
    param([scriptblock]$Action,[string]$Expected)
    $threw = $false
    try { & $Action } catch {
        $threw = $true
        if($_.Exception.Message -notmatch [regex]::Escape($Expected)) {
            throw "Expected error containing '$Expected', got '$($_.Exception.Message)'."
        }
    }
    if(-not $threw) { throw "Expected action to throw an error containing '$Expected'." }
}

try {
    $oneDriveRoot = Join-Path $tempRoot 'OneDrive - Money Machine'
    $terminalRoot = Join-Path $tempRoot 'MetaQuotes\Terminal'
    $sourceDir = Join-Path $terminalRoot 'ABC123\MQL4\Files'
    New-Item -ItemType Directory -Path $oneDriveRoot,$sourceDir -Force | Out-Null
    $sourceCsv = Join-Path $sourceDir 'AGOLD___Baskets.csv'
    Set-Content -LiteralPath $sourceCsv -Value 'discovery-only-fixture' -Encoding utf8

    Import-Module -Name $ModulePath -Force -ErrorAction Stop
    $discovery = Get-MoneyMachineSetupDiscovery -OneDriveCandidates @($oneDriveRoot) -TerminalDataRoot $terminalRoot

    if(@($discovery.OneDriveRoots).Count -ne 1) { throw 'Discovery must return exactly one existing OneDrive root.' }
    if([string]$discovery.OneDriveRoots[0].Path -ne (Resolve-Path -LiteralPath $oneDriveRoot).Path) { throw 'Discovery must return the resolved OneDrive path.' }
    if(@($discovery.Sources).Count -ne 1) { throw 'Discovery must return exactly one AGOLD baskets CSV.' }
    if([string]$discovery.Sources[0].Path -ne (Resolve-Path -LiteralPath $sourceCsv).Path) { throw 'Discovery must return the resolved CSV path.' }
    if([string]$discovery.Sources[0].TerminalId -ne 'ABC123') { throw 'Discovery must expose the terminal identifier for operator selection.' }

    $fixturePath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'fixtures\AGOLD___Baskets_v3.csv'
    Copy-Item -LiteralPath $fixturePath -Destination $sourceCsv -Force
    $valid = Test-MoneyMachineSetupRequest -VpsName ' VPS London 01 ' -ExpectedMT4Login '892522910' -SourceCsv $sourceCsv -OneDriveRoot $oneDriveRoot
    if($valid.VpsName -cne 'VPS London 01') { throw 'Validation must trim the friendly VPS name.' }
    if($valid.ExpectedMT4Login -cne '892522910') { throw 'Validation must preserve the digit-only MT4 login.' }
    if($valid.SourceCsv -cne (Resolve-Path -LiteralPath $sourceCsv).Path) { throw 'Validation must resolve the CSV path.' }
    if($valid.OneDriveRoot -cne (Resolve-Path -LiteralPath $oneDriveRoot).Path) { throw 'Validation must resolve the OneDrive root.' }

    $notCsv = Join-Path $sourceDir 'AGOLD___Baskets.txt'
    Copy-Item -LiteralPath $fixturePath -Destination $notCsv
    Assert-ThrowsLike -Expected 'VPS name' -Action { Test-MoneyMachineSetupRequest -VpsName ' ' -ExpectedMT4Login '892522910' -SourceCsv $sourceCsv -OneDriveRoot $oneDriveRoot | Out-Null }
    Assert-ThrowsLike -Expected 'account number' -Action { Test-MoneyMachineSetupRequest -VpsName 'VPS' -ExpectedMT4Login '89A' -SourceCsv $sourceCsv -OneDriveRoot $oneDriveRoot | Out-Null }
    Assert-ThrowsLike -Expected 'Source CSV' -Action { Test-MoneyMachineSetupRequest -VpsName 'VPS' -ExpectedMT4Login '892522910' -SourceCsv (Join-Path $tempRoot 'missing.csv') -OneDriveRoot $oneDriveRoot | Out-Null }
    Assert-ThrowsLike -Expected '.csv' -Action { Test-MoneyMachineSetupRequest -VpsName 'VPS' -ExpectedMT4Login '892522910' -SourceCsv $notCsv -OneDriveRoot $oneDriveRoot | Out-Null }
    Assert-ThrowsLike -Expected 'OneDrive root' -Action { Test-MoneyMachineSetupRequest -VpsName 'VPS' -ExpectedMT4Login '892522910' -SourceCsv $sourceCsv -OneDriveRoot (Join-Path $tempRoot 'missing-onedrive') | Out-Null }
    Assert-ThrowsLike -Expected 'AccountNumber' -Action { Test-MoneyMachineSetupRequest -VpsName 'VPS' -ExpectedMT4Login '9999' -SourceCsv $sourceCsv -OneDriveRoot $oneDriveRoot | Out-Null }

    $configPath = Join-Path $tempRoot 'accounts.csv'
    @([pscustomobject]@{
        Enabled = 'true'
        ExpectedMT4Login = '1111'
        SourceCsv = 'C:\Existing\AGOLD___Baskets.csv'
        OneDriveRoot = 'C:\Existing\OneDrive'
    }) | Export-Csv -LiteralPath $configPath -NoTypeInformation -Encoding utf8

    $saved = Save-MoneyMachineAccountConfig -ConfigPath $configPath -Account $valid
    if(-not $saved.Changed) { throw 'Adding a new account must report a changed configuration.' }
    if(-not (Test-Path -LiteralPath $saved.BackupPath -PathType Leaf)) { throw 'Updating an existing config must create a backup.' }
    $savedRows = @(Import-Csv -LiteralPath $configPath)
    if($savedRows.Count -ne 2) { throw 'Account upsert must preserve an existing account and add the new one.' }
    $expectedColumns = 'Enabled,VpsName,ExpectedMT4Login,SourceCsv,OneDriveRoot'
    if(($savedRows[0].PSObject.Properties.Name -join ',') -cne $expectedColumns) { throw 'Config must use the exact five-column contract and order.' }
    if($savedRows[1].VpsName -cne 'VPS London 01') { throw 'Saved configuration must include the friendly VPS name.' }

    $replacement = [pscustomobject]@{
        VpsName = 'VPS London Replacement'
        ExpectedMT4Login = $valid.ExpectedMT4Login
        SourceCsv = $valid.SourceCsv
        OneDriveRoot = $valid.OneDriveRoot
    }
    Save-MoneyMachineAccountConfig -ConfigPath $configPath -Account $replacement | Out-Null
    $replacedRows = @(Import-Csv -LiteralPath $configPath)
    if($replacedRows.Count -ne 2) { throw 'Replacing an account by login must not create a duplicate row.' }
    if(($replacedRows | Where-Object ExpectedMT4Login -eq '892522910').VpsName -cne 'VPS London Replacement') { throw 'Account replacement must update the matching login.' }

    $setupConfig = Join-Path $tempRoot 'setup\accounts.csv'
    $runtimeRoot = Join-Path $tempRoot 'runtime'
    $setup = Invoke-MoneyMachineSetup -Request $valid -ConfigPath $setupConfig -RuntimeRoot $runtimeRoot -SkipTaskRegistration -StableCheckSeconds 0
    if($setup.Status -cne 'Success') { throw 'Staged setup must return Success.' }
    if(@($setup.Stages | Where-Object Code -eq 'LocalPublished').Count -ne 1) { throw 'Staged setup must report the LocalPublished stage.' }
    $destination = Join-Path $oneDriveRoot 'AmarTrading\Account_892522910\Baskets.csv'
    $heartbeat = Join-Path $oneDriveRoot 'AmarTrading\Account_892522910\SyncStatus.json'
    if(-not (Test-Path -LiteralPath $destination -PathType Leaf)) { throw 'Staged setup must publish Baskets.csv.' }
    if(-not (Test-Path -LiteralPath $heartbeat -PathType Leaf)) { throw 'Staged setup must publish SyncStatus.json.' }

    $rollbackConfig = Join-Path $tempRoot 'rollback\accounts.csv'
    New-Item -ItemType Directory -Path (Split-Path -Parent $rollbackConfig) -Force | Out-Null
    Set-Content -LiteralPath $rollbackConfig -Value @('Enabled,VpsName,ExpectedMT4Login,SourceCsv,OneDriveRoot','false,Old,7777,C:\old.csv,C:\old-drive') -Encoding utf8
    $beforeRollback = (Get-FileHash -LiteralPath $rollbackConfig -Algorithm SHA256).Hash
    $blockedOneDrive = Join-Path $tempRoot 'blocked-onedrive'
    New-Item -ItemType Directory -Path $blockedOneDrive -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $blockedOneDrive 'AmarTrading') -Value 'blocks destination directory creation' -Encoding utf8
    $blockedRequest = Test-MoneyMachineSetupRequest -VpsName 'Blocked VPS' -ExpectedMT4Login '892522910' -SourceCsv $sourceCsv -OneDriveRoot $blockedOneDrive
    Assert-ThrowsLike -Expected 'AmarTrading' -Action {
        Invoke-MoneyMachineSetup -Request $blockedRequest -ConfigPath $rollbackConfig -RuntimeRoot (Join-Path $tempRoot 'rollback-runtime') -SkipTaskRegistration -StableCheckSeconds 0 | Out-Null
    }
    $afterRollback = (Get-FileHash -LiteralPath $rollbackConfig -Algorithm SHA256).Hash
    if($beforeRollback -cne $afterRollback) { throw 'A failed first publication must restore the original config bytes.' }

    Write-Host 'MoneyMachine setup discovery, validation, config, publication, and rollback tests passed.'
}
finally {
    if(Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
