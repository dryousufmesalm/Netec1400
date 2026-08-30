[CmdletBinding()]
param(
    [string]$ModulePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if([string]::IsNullOrWhiteSpace($ModulePath)) {
    $ModulePath = Join-Path $PSScriptRoot '..\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1'
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("AmmarTradingBatchSetupTest_" + [guid]::NewGuid().ToString('N'))
$fixturePath = Join-Path $PSScriptRoot 'fixtures\AGOLD___Baskets_v3.csv'
$originalOneDrive = $env:OneDrive
$originalOneDriveCommercial = $env:OneDriveCommercial
$originalOneDriveConsumer = $env:OneDriveConsumer

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if(-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual,$Expected,[string]$Message)
    if($Actual -cne $Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
}

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

function New-AccountCsv {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AccountNumber,
        [Parameter(Mandatory)][string]$BrokerName,
        [switch]$InvalidSecondRow
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $rows = @(Import-Csv -LiteralPath $fixturePath)
    $rows[0].AccountNumber = $AccountNumber
    $rows[0].BrokerName = $BrokerName
    if($InvalidSecondRow) {
        $badRow = $rows[0].PSObject.Copy()
        $badRow.BasketID = '2'
        $badRow.Direction = 'SIDEWAYS'
        @($rows[0],$badRow) | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8
    } else {
        $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8
    }
    return $Path
}

function Get-ManualDiscovery {
    param([Parameter(Mandatory)][string[]]$Paths)
    $missingTerminalRoot = Join-Path $tempRoot 'missing-terminal-root'
    return @(Get-AmmarTradingMt4Accounts -TerminalDataRoot $missingTerminalRoot -ManualCsv $Paths)
}

function New-BatchRequest {
    param(
        [Parameter(Mandatory)][object[]]$Discoveries,
        [Parameter(Mandatory)][string]$OneDriveRoot,
        [string]$VpsName = 'VPS London Batch'
    )

    $env:OneDrive = $OneDriveRoot
    $env:OneDriveCommercial = $null
    $env:OneDriveConsumer = $null
    Set-TestOneDriveRegistration -Root $OneDriveRoot
    return [pscustomobject]@{
        VpsName = $VpsName
        OneDriveRoot = $OneDriveRoot
        Accounts = @($Discoveries | ForEach-Object {
            [pscustomobject]@{
                DiscoveryId = $_.DiscoveryId
                ExpectedMT4Login = $_.AccountNumber
                SourceCsv = $_.SourceCsv
            }
        })
    }
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Import-Module -Name $ModulePath -Force -ErrorAction Stop
    $setupModule = Get-Module -Name MoneyMachineSyncSetup
    function Set-TestOneDriveRegistration {
        param([Parameter(Mandatory)][string]$Root)
        & $setupModule {
            param($RegisteredRoot)
            $script:AmmarTradingBatchTestRegisteredOneDriveRoot = $RegisteredRoot
            $script:AmmarTradingOneDriveRegistrationResolver = { @($script:AmmarTradingBatchTestRegisteredOneDriveRoot) }
        } $Root
    }

    # A missing batch entry point is the intentional RED failure before Task 3 implementation.
    $successRoot = Join-Path $tempRoot 'success'
    $successOneDrive = Join-Path $successRoot 'OneDrive'
    $successRuntime = Join-Path $successRoot 'runtime'
    $successConfig = Join-Path $successRoot 'accounts.csv'
    New-Item -ItemType Directory -Path $successOneDrive -Force | Out-Null
    $sourceOne = New-AccountCsv -Path (Join-Path $successRoot 'sources\one.csv') -AccountNumber '10000001' -BrokerName 'Broker Alpha'
    $sourceTwo = New-AccountCsv -Path (Join-Path $successRoot 'sources\two.csv') -AccountNumber '20000002' -BrokerName 'Broker Beta'
    $discoveries = Get-ManualDiscovery -Paths @($sourceOne,$sourceTwo)
    Assert-Equal -Actual $discoveries.Count -Expected 2 -Message 'The success fixture must discover two accounts.'

    @([pscustomobject][ordered]@{
        Enabled = 'true'
        VpsName = 'Unselected VPS'
        ExpectedMT4Login = '30000003'
        SourceCsv = (Join-Path $successRoot 'missing-unselected.csv')
        OneDriveRoot = $successOneDrive
    }) | Export-Csv -LiteralPath $successConfig -NoTypeInformation -Encoding utf8

    $legacyFile = Join-Path $successOneDrive 'Money Machine\Account_10000001\History\prior.csv'
    New-Item -ItemType Directory -Path (Split-Path -Parent $legacyFile) -Force | Out-Null
    Set-Content -LiteralPath $legacyFile -Value 'legacy-history' -Encoding utf8

    $request = New-BatchRequest -Discoveries $discoveries -OneDriveRoot $successOneDrive
    $result = Invoke-AmmarTradingBatchSetup -Request $request -ConfigPath $successConfig -RuntimeRoot $successRuntime -SkipTaskRegistration -StableCheckSeconds 0
    Assert-Equal -Actual $result.Status -Expected 'Success' -Message 'A valid two-account batch must succeed.'
    Assert-Equal -Actual @($result.Accounts).Count -Expected 2 -Message 'A valid two-account batch must return two account results.'
    Assert-Equal -Actual @(Import-Csv -LiteralPath $successConfig).Count -Expected 3 -Message 'A batch upsert must preserve the unselected row.'
    Assert-True -Condition (-not [bool]$result.CloudDeliveryVerified) -Message 'Local publication must not claim OneDrive cloud delivery.'
    Assert-Equal -Actual ($result.Accounts[0].PSObject.Properties.Name -join ',') -Expected 'AccountNumber,BrokerName,Destination,LocalPublished,TaskState' -Message 'Batch account results must preserve the public field contract and order.'
    Assert-True -Condition ([bool]$result.Accounts[0].LocalPublished) -Message 'Every successful selected account must report local publication.'
    Assert-Equal -Actual $result.Accounts[0].TaskState -Expected 'RegistrationSkipped' -Message 'Staging acceptance must report skipped task registration.'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $successOneDrive 'AmmarTrading\Account_10000001\Baskets.csv') -PathType Leaf) -Message 'The first selected account must publish to the canonical destination.'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $successOneDrive 'AmmarTrading\Account_20000002\Baskets.csv') -PathType Leaf) -Message 'The second selected account must publish to the canonical destination.'

    $migratedFile = Join-Path $successOneDrive 'AmmarTrading\Account_10000001\History\prior.csv'
    Assert-True -Condition (Test-Path -LiteralPath $legacyFile -PathType Leaf) -Message 'Legacy migration must leave source data untouched.'
    Assert-True -Condition (Test-Path -LiteralPath $migratedFile -PathType Leaf) -Message 'Legacy migration must copy files below selected account folders.'
    Assert-Equal -Actual (Get-FileHash -LiteralPath $legacyFile -Algorithm SHA256).Hash -Expected (Get-FileHash -LiteralPath $migratedFile -Algorithm SHA256).Hash -Message 'A migrated legacy file must match its source hash.'
    $alreadyPresent = Copy-AmmarTradingLegacyData -OneDriveRoot $successOneDrive -AccountNumbers @('10000001')
    Assert-Equal -Actual $alreadyPresent.AlreadyPresent -Expected 1 -Message 'An identical migrated file must be counted as already present.'
    Assert-Equal -Actual $alreadyPresent.Copied -Expected 0 -Message 'An identical migrated file must not be copied again.'

    # Migration must carry the same create-new temporary handle from verified
    # copy through no-replace publication. This seam targets the former gap by
    # attempting a regular-file substitution after the temp bytes exist.
    $heldLegacyFile = Join-Path $successOneDrive 'Money Machine\Account_10000001\History\held.csv'
    $heldMigrationDestination = Join-Path $successOneDrive 'AmmarTrading\Account_10000001\History\held.csv'
    [IO.File]::WriteAllText($heldLegacyFile, 'held-migration-source', (New-Object Text.UTF8Encoding($false)))
    & $setupModule {
        param($Destination)
        $script:AmmarTradingBatchHeldMigrationDestination = [IO.Path]::GetFullPath($Destination)
        $script:AmmarTradingBatchHeldMigrationSubstitutionBlocked = $false
        $script:AmmarTradingBatchHeldMigrationSubstitutionSucceeded = $false
        $script:AmmarTradingBatchHeldMigrationAttackHook = {
            param($Description,$Path,$Destination)
            if($Description -cne 'Legacy migration publication') { return }
            $temporary = $null
            if(-not [string]::IsNullOrWhiteSpace([string]$Destination) -and
               [IO.Path]::GetFullPath([string]$Destination) -ieq $script:AmmarTradingBatchHeldMigrationDestination -and
               (Test-Path -LiteralPath ([string]$Path) -PathType Leaf)) {
                $temporary = [string]$Path
            } else {
                $prefix = [IO.Path]::GetFileName($script:AmmarTradingBatchHeldMigrationDestination) + '.'
                $temporaryItem = @(Get-ChildItem -LiteralPath (Split-Path -Parent $script:AmmarTradingBatchHeldMigrationDestination) -File -Force -ErrorAction Stop |
                    Where-Object { $_.Name.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and $_.Name.EndsWith('.tmp',[StringComparison]::OrdinalIgnoreCase) } |
                    Select-Object -First 1)
                if($temporaryItem.Count -eq 1) { $temporary = [string]$temporaryItem[0].FullName }
            }
            if([string]::IsNullOrWhiteSpace($temporary)) { return }
            try {
                Move-Item -LiteralPath $temporary -Destination "$temporary.verified" -ErrorAction Stop
                [IO.File]::WriteAllText($temporary, 'attacker-migration-bytes', (New-Object Text.UTF8Encoding($false)))
                $script:AmmarTradingBatchHeldMigrationSubstitutionSucceeded = $true
            } catch {
                $script:AmmarTradingBatchHeldMigrationSubstitutionBlocked = $true
            }
        }
        $script:AmmarTradingTrustedPathOperationHook = $script:AmmarTradingBatchHeldMigrationAttackHook
        $script:AmmarTradingTrustedFilePublicationHook = $script:AmmarTradingBatchHeldMigrationAttackHook
    } $heldMigrationDestination
    $heldMigration = Copy-AmmarTradingLegacyData -OneDriveRoot $successOneDrive -AccountNumbers @('10000001')
    $heldMigrationAttack = & $setupModule {
        [pscustomobject]@{
            Blocked = $script:AmmarTradingBatchHeldMigrationSubstitutionBlocked
            Succeeded = $script:AmmarTradingBatchHeldMigrationSubstitutionSucceeded
        }
    }
    Assert-True -Condition ([bool]$heldMigrationAttack.Blocked -and -not [bool]$heldMigrationAttack.Succeeded) -Message 'A verified legacy migration temporary file must remain held so regular-file substitution is blocked before publication.'
    Assert-Equal -Actual $heldMigration.Copied -Expected 1 -Message 'A protected legacy migration must copy its verified source once.'
    Assert-Equal -Actual (Get-Content -LiteralPath $heldMigrationDestination -Raw) -Expected 'held-migration-source' -Message 'Legacy migration must never install attacker bytes substituted after verification.'
    & $setupModule {
        $script:AmmarTradingTrustedPathOperationHook = $null
        $script:AmmarTradingTrustedFilePublicationHook = $null
    }

    $racingLegacyFile = Join-Path $successOneDrive 'Money Machine\Account_10000001\History\racing.csv'
    $racingDestination = Join-Path $successOneDrive 'AmmarTrading\Account_10000001\History\racing.csv'
    Set-Content -LiteralPath $racingLegacyFile -Value 'legacy-racing-source' -Encoding utf8
    & $setupModule {
        param($Destination)
        $script:AmmarTradingBatchRaceDestination = $Destination
        $script:AmmarTradingTrustedFilePublicationHook = {
            param($Description,$Temporary,$Destination)
            if($Description -ceq 'Legacy migration publication') {
                Set-Content -LiteralPath $script:AmmarTradingBatchRaceDestination -Value 'concurrent-destination' -Encoding utf8
                $script:AmmarTradingTrustedFilePublicationHook = $null
            }
        }
    } $racingDestination
    $racingConflict = Copy-AmmarTradingLegacyData -OneDriveRoot $successOneDrive -AccountNumbers @('10000001')
    Assert-Equal -Actual $racingConflict.Conflict -Expected 1 -Message 'A destination created during legacy publication must be counted as a conflict.'
    Assert-Equal -Actual $racingConflict.Copied -Expected 0 -Message 'Legacy migration must not replace a destination created during publication.'
    Assert-Equal -Actual (Get-Content -LiteralPath $racingDestination -Raw) -Expected "concurrent-destination`r`n" -Message 'Legacy migration must preserve a destination created during publication.'
    Remove-Item -LiteralPath $racingLegacyFile,$racingDestination -Force -ErrorAction Stop

    Set-Content -LiteralPath $migratedFile -Value 'different-canonical-history' -Encoding utf8
    $conflict = Copy-AmmarTradingLegacyData -OneDriveRoot $successOneDrive -AccountNumbers @('10000001')
    Assert-Equal -Actual $conflict.Conflict -Expected 1 -Message 'A different destination file must be counted as a conflict.'
    Assert-Equal -Actual (Get-Content -LiteralPath $migratedFile -Raw) -Expected "different-canonical-history`r`n" -Message 'Legacy migration must never overwrite a different destination file.'

    $invalidRoot = Join-Path $tempRoot 'invalid'
    $invalidOneDrive = Join-Path $invalidRoot 'OneDrive'
    $invalidConfig = Join-Path $invalidRoot 'accounts.csv'
    New-Item -ItemType Directory -Path $invalidOneDrive -Force | Out-Null
    Set-Content -LiteralPath $invalidConfig -Value @('Enabled,VpsName,ExpectedMT4Login,SourceCsv,OneDriveRoot','false,Existing,40000004,C:\existing.csv,C:\existing-drive') -Encoding utf8
    $invalidConfigHash = (Get-FileHash -LiteralPath $invalidConfig -Algorithm SHA256).Hash
    $validForInvalidBatch = New-AccountCsv -Path (Join-Path $invalidRoot 'sources\valid.csv') -AccountNumber '40000004' -BrokerName 'Broker Valid'
    $strictlyInvalid = New-AccountCsv -Path (Join-Path $invalidRoot 'sources\strict-invalid.csv') -AccountNumber '50000005' -BrokerName 'Broker Invalid' -InvalidSecondRow
    $invalidDiscoveries = Get-ManualDiscovery -Paths @($validForInvalidBatch,$strictlyInvalid)
    Assert-Equal -Actual @($invalidDiscoveries | Where-Object Eligibility -eq 'Ready').Count -Expected 2 -Message 'The strict-invalid fixture must pass bounded discovery so batch validation catches the later bad row.'
    $invalidRequest = New-BatchRequest -Discoveries $invalidDiscoveries -OneDriveRoot $invalidOneDrive
    Assert-ThrowsLike -Expected 'Direction' -Action {
        Invoke-AmmarTradingBatchSetup -Request $invalidRequest -ConfigPath $invalidConfig -RuntimeRoot (Join-Path $invalidRoot 'runtime') -SkipTaskRegistration -StableCheckSeconds 0 | Out-Null
    }
    Assert-Equal -Actual (Get-FileHash -LiteralPath $invalidConfig -Algorithm SHA256).Hash -Expected $invalidConfigHash -Message 'Failure of any strict account validation must leave the configuration byte-for-byte unchanged.'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $invalidOneDrive 'AmmarTrading'))) -Message 'Failure of any strict account validation must publish no selected destination.'

    $staleRoot = Join-Path $tempRoot 'stale'
    $staleOneDrive = Join-Path $staleRoot 'OneDrive'
    New-Item -ItemType Directory -Path $staleOneDrive -Force | Out-Null
    $staleSource = New-AccountCsv -Path (Join-Path $staleRoot 'source.csv') -AccountNumber '60000006' -BrokerName 'Broker Stale'
    $staleDiscovery = @(Get-ManualDiscovery -Paths @($staleSource))[0]
    [IO.File]::SetLastWriteTimeUtc($staleSource, [DateTime]::UtcNow.AddSeconds(5))
    $staleRequest = New-BatchRequest -Discoveries @($staleDiscovery) -OneDriveRoot $staleOneDrive
    $staleConfig = Join-Path $staleRoot 'accounts.csv'
    Assert-ThrowsLike -Expected 'stale' -Action {
        Invoke-AmmarTradingBatchSetup -Request $staleRequest -ConfigPath $staleConfig -RuntimeRoot (Join-Path $staleRoot 'runtime') -SkipTaskRegistration -StableCheckSeconds 0 | Out-Null
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath $staleConfig)) -Message 'A stale discovery identity must be rejected before creating configuration.'

    $duplicateRequest = New-BatchRequest -Discoveries @($discoveries[0],$discoveries[0]) -OneDriveRoot $successOneDrive
    Assert-ThrowsLike -Expected 'duplicate' -Action {
        Invoke-AmmarTradingBatchSetup -Request $duplicateRequest -ConfigPath (Join-Path $tempRoot 'duplicate\accounts.csv') -RuntimeRoot (Join-Path $tempRoot 'duplicate\runtime') -SkipTaskRegistration -StableCheckSeconds 0 | Out-Null
    }

    $rollbackRoot = Join-Path $tempRoot 'rollback'
    $rollbackOneDrive = Join-Path $rollbackRoot 'OneDrive'
    $rollbackConfig = Join-Path $rollbackRoot 'accounts.csv'
    New-Item -ItemType Directory -Path (Join-Path $rollbackOneDrive 'AmmarTrading') -Force | Out-Null
    Set-Content -LiteralPath $rollbackConfig -Value @('Enabled,VpsName,ExpectedMT4Login,SourceCsv,OneDriveRoot','false,Original,70000007,C:\original.csv,C:\original-drive') -Encoding utf8
    $rollbackHash = (Get-FileHash -LiteralPath $rollbackConfig -Algorithm SHA256).Hash
    $rollbackOne = New-AccountCsv -Path (Join-Path $rollbackRoot 'sources\one.csv') -AccountNumber '70000007' -BrokerName 'Broker Rollback One'
    $rollbackTwo = New-AccountCsv -Path (Join-Path $rollbackRoot 'sources\two.csv') -AccountNumber '80000008' -BrokerName 'Broker Rollback Two'
    $rollbackDiscoveries = Get-ManualDiscovery -Paths @($rollbackOne,$rollbackTwo)
    Set-Content -LiteralPath (Join-Path $rollbackOneDrive 'AmmarTrading\Account_80000008') -Value 'blocks second account publication' -Encoding utf8
    $rollbackRequest = New-BatchRequest -Discoveries $rollbackDiscoveries -OneDriveRoot $rollbackOneDrive
    Assert-ThrowsLike -Expected '80000008' -Action {
        Invoke-AmmarTradingBatchSetup -Request $rollbackRequest -ConfigPath $rollbackConfig -RuntimeRoot (Join-Path $rollbackRoot 'runtime') -SkipTaskRegistration -StableCheckSeconds 0 | Out-Null
    }
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $rollbackOneDrive 'AmmarTrading\Account_70000007\Baskets.csv') -PathType Leaf) -Message 'The rollback fixture must prove the first account published before the later failure.'
    Assert-Equal -Actual (Get-FileHash -LiteralPath $rollbackConfig -Algorithm SHA256).Hash -Expected $rollbackHash -Message 'A partial first-publication failure must restore the original configuration exactly once.'

    $reparseRoot = Join-Path $tempRoot 'reparse'
    $reparseOneDrive = Join-Path $reparseRoot 'OneDrive'
    $reparseTarget = Join-Path $reparseRoot 'outside-target'
    $reparseAccount = Join-Path $reparseOneDrive 'AmarTrading\Account_90000009'
    New-Item -ItemType Directory -Path $reparseOneDrive,$reparseTarget,$reparseAccount -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $reparseTarget 'outside.csv') -Value 'must-not-migrate' -Encoding utf8
    New-Item -ItemType Junction -Path (Join-Path $reparseAccount 'linked') -Target $reparseTarget | Out-Null
    $env:OneDrive = $reparseOneDrive
    $env:OneDriveCommercial = $null
    $env:OneDriveConsumer = $null
    Set-TestOneDriveRegistration -Root $reparseOneDrive
    Assert-ThrowsLike -Expected 'reparse' -Action {
        Copy-AmmarTradingLegacyData -OneDriveRoot $reparseOneDrive -AccountNumbers @('90000009') | Out-Null
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $reparseOneDrive 'AmmarTrading\Account_90000009\linked\outside.csv'))) -Message 'Migration must not traverse a legacy reparse point.'

    Write-Host 'AmmarTrading transactional batch setup and legacy migration tests passed.'
}
finally {
    $env:OneDrive = $originalOneDrive
    $env:OneDriveCommercial = $originalOneDriveCommercial
    $env:OneDriveConsumer = $originalOneDriveConsumer
    if(Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
