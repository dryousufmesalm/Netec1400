[CmdletBinding()]
param(
    [string]$RunnerPath,
    [string]$InstallerAcceptancePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if([string]::IsNullOrWhiteSpace($RunnerPath)) { $RunnerPath = Join-Path $PSScriptRoot 'Run-WindowsProductionAcceptance.ps1' }
if([string]::IsNullOrWhiteSpace($InstallerAcceptancePath)) { $InstallerAcceptancePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'windows\scripts\Test-AmmarTradingSyncAcceptance.ps1' }

if(-not (Test-Path -LiteralPath $RunnerPath -PathType Leaf)) {
    throw "Windows production acceptance runner is missing: $RunnerPath"
}

$runnerSource = Get-Content -LiteralPath $RunnerPath -Raw
$tokens=$null; $parseErrors=$null
$runnerAst=[Management.Automation.Language.Parser]::ParseFile($RunnerPath,[ref]$tokens,[ref]$parseErrors)
if(@($parseErrors).Count -ne 0) { throw 'Production acceptance runner does not parse.' }
$productionParameterNames=@($runnerAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
foreach($forbiddenProductionParameter in @('MachineIdentityHash','OneDriveProcessRunning','ReceiptAttributeValue','TaskEvidenceProvider')) {
    if($forbiddenProductionParameter -in $productionParameterNames) { throw "A test seam is reachable from the production CLI: $forbiddenProductionParameter" }
}
foreach($requiredParameter in @(
    '[ValidateSet(''Staging'',''Vps'',''ReportingPc'')][string]$AcceptanceRole',
    '[string]$VpsName',
    '[string[]]$ExpectedAccountNumber',
    '[string]$OneDriveRoot',
    '[string]$EvidenceOutputPath',
    '[string]$VpsEvidencePath'
)) {
    if($runnerSource -notmatch [regex]::Escape($requiredParameter)) {
        throw "Production acceptance is missing the explicit end-to-end parameter contract: $requiredParameter"
    }
}

$installerAcceptanceSource = Get-Content -LiteralPath $InstallerAcceptancePath -Raw
foreach($installerContract in @(
    '[string]$ExpectedInstallerSha256',
    '[switch]$ProductionInstallOnly',
    'Production installation requires an explicit lowercase SHA-256 pin.'
)) {
    if($installerAcceptanceSource -notmatch [regex]::Escape($installerContract)) {
        throw "Installer acceptance is missing the production hash-pin contract: $installerContract"
    }
}
foreach($requiredFunction in @(
    'function Get-AmmarTradingVpsAcceptanceEvidence',
    'function Get-AmmarTradingReportingAcceptanceEvidence'
)) {
    if($runnerSource -notmatch [regex]::Escape($requiredFunction)) {
        throw "Production acceptance is missing the role-separated evidence function: $requiredFunction"
    }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("MoneyMachineAcceptanceContract_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$oldOneDrive = $env:OneDrive
try {
    . $RunnerPath -StagingRoot $tempRoot -AsLibrary

    $fixtureRoot = Join-Path $tempRoot 'e2e-fixture'
    $oneDriveRoot = Join-Path $fixtureRoot 'OneDrive'
    $runtimeRoot = Join-Path $fixtureRoot 'runtime'
    $sourceRoot = Join-Path $fixtureRoot 'sources'
    $evidenceRoot = Join-Path $fixtureRoot 'evidence'
    $arbitraryRoot = Join-Path $fixtureRoot 'arbitrary-cloud-folder'
    New-Item -ItemType Directory -Path $oneDriveRoot,$runtimeRoot,$sourceRoot,$evidenceRoot,$arbitraryRoot -Force | Out-Null
    $env:OneDrive = $oneDriveRoot
    $setupModule = Get-Module MoneyMachineSyncSetup
    & $setupModule {
        param($Root)
        $script:AmmarTradingAcceptanceTestRegisteredOneDriveRoot = $Root
        $script:AmmarTradingOneDriveRegistrationResolver = { @($script:AmmarTradingAcceptanceTestRegisteredOneDriveRoot) }
    } $oneDriveRoot
    $accounts = @('10000001','10000002')
    $mappings = [Collections.Generic.List[object]]::new()
    foreach($account in $accounts) {
        $source = Join-Path $sourceRoot "$account.csv"
        $destinationRoot = Join-Path $oneDriveRoot "AmmarTrading\Account_$account"
        New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
        $destination = Join-Path $destinationRoot 'Baskets.csv'
        $rows = @(Import-Csv -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\fixtures\AGOLD___Baskets_v3.csv'))
        foreach($row in $rows) { $row.AccountNumber=$account; $row.BrokerName='Acceptance Broker' }
        $rows | Export-Csv -LiteralPath $source -NoTypeInformation -Encoding utf8
        Copy-Item -LiteralPath $source -Destination $destination
        $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        [ordered]@{
            AccountNumber=$account
            Status='Success'
            SourceHash=$hash
            DestinationHash=$hash
            CloudDeliveryVerified=$false
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destinationRoot 'SyncStatus.json') -Encoding utf8
        $mappings.Add([pscustomobject]@{ Enabled='true'; VpsName='Demo VPS'; ExpectedMT4Login=$account; SourceCsv=$source; OneDriveRoot=$oneDriveRoot })
    }
    $configPath = Join-Path $runtimeRoot 'accounts.csv'
    $mappings | Export-Csv -LiteralPath $configPath -NoTypeInformation -Encoding utf8

    Set-AmmarTradingAcceptanceTestContext -MachineIdentityHash ('a' * 64) -OneDriveProcessRunning $true -ReceiptAttributeValue 0 -TaskEvidenceProvider { [pscustomobject]@{ TaskState='Ready'; LastTaskResult=0 } }
    $vpsEvidence = Get-AmmarTradingVpsAcceptanceEvidence -VpsName 'Demo VPS' -ExpectedAccountNumber $accounts -OneDriveRoot $oneDriveRoot -ConfigPath $configPath
    if($vpsEvidence.EvidenceRole -cne 'Vps' -or [bool]$vpsEvidence.CloudDeliveryVerified) {
        throw 'VPS evidence must be explicitly role-bound and must never claim cloud delivery.'
    }
    if($vpsEvidence.MachineIdentity.Scheme -cne 'sha256-domain-separated-machine-guid' -or $vpsEvidence.MachineIdentity.Version -ne 1 -or $vpsEvidence.MachineIdentity.Hash -cne ('a' * 64)) {
        throw 'VPS evidence does not preserve the privacy-safe versioned machine identity contract.'
    }
    if($vpsEvidence.OneDrive.RootIdentity.Scheme -cne 'sha256-domain-separated-canonical-root' -or $vpsEvidence.OneDrive.RootIdentity.Version -ne 1 -or [string]::IsNullOrWhiteSpace($vpsEvidence.OneDrive.RootIdentity.Hash)) {
        throw 'VPS evidence does not preserve the privacy-safe versioned OneDrive root identity contract.'
    }
    if(@($vpsEvidence.Accounts).Count -ne 2 -or @($vpsEvidence.Accounts | Where-Object { $_.SourceHash -cne $_.DestinationHash }).Count -ne 0) {
        throw 'VPS evidence must prove exactly two independently hash-matched account publications.'
    }
    $shareableVpsJson=$vpsEvidence | ConvertTo-Json -Depth 10
    foreach($privateValue in @($oneDriveRoot,$sourceRoot,[Environment]::MachineName)) {
        if($shareableVpsJson -match [regex]::Escape($privateValue)) { throw 'VPS evidence leaked a raw machine name or filesystem path.' }
    }

    $vpsEvidencePath = Join-Path $fixtureRoot 'vps-evidence.json'
    Write-AtomicAcceptanceReport -Path $vpsEvidencePath -Json ($vpsEvidence | ConvertTo-Json -Depth 8)
    Set-AmmarTradingAcceptanceTestContext -MachineIdentityHash ('b' * 64) -OneDriveProcessRunning $true -ReceiptAttributeValue 0 -TaskEvidenceProvider { [pscustomobject]@{ TaskState='Ready'; LastTaskResult=0 } }
    $reportingEvidence = Get-AmmarTradingReportingAcceptanceEvidence -VpsName 'Demo VPS' -ExpectedAccountNumber $accounts -OneDriveRoot $oneDriveRoot -VpsEvidencePath $vpsEvidencePath
    if($reportingEvidence.EvidenceRole -cne 'ReportingPc' -or -not [bool]$reportingEvidence.PhysicalReceiptObserved -or $reportingEvidence.PSObject.Properties['CloudDeliveryVerified']) {
        throw 'Reporting evidence must record a physical receipt observation without claiming provider-attested cloud delivery.'
    }
    if(@($reportingEvidence.Accounts | Where-Object { $_.HydrationState -cne 'Hydrated' -or -not [bool]$_.PhysicalReceiptObserved }).Count -ne 0) { throw 'Reporting evidence did not prove hydrated readable local bytes.' }

    $mismatchedDestination = Join-Path $oneDriveRoot 'AmmarTrading\Account_10000001\Baskets.csv'
    Add-Content -LiteralPath $mismatchedDestination -Value '# independent receipt hash mismatch' -Encoding utf8
    $hashMismatchRejected = $false
    try { $null = Get-AmmarTradingReportingAcceptanceEvidence -VpsName 'Demo VPS' -ExpectedAccountNumber $accounts -OneDriveRoot $oneDriveRoot -VpsEvidencePath $vpsEvidencePath } catch { $hashMismatchRejected = $true }
    if(-not $hashMismatchRejected) { throw 'Reporting acceptance accepted hydrated bytes whose hash differs from independent VPS evidence.' }
    Copy-Item -LiteralPath $mappings[0].SourceCsv -Destination $mismatchedDestination -Force

    Set-AmmarTradingAcceptanceTestContext -MachineIdentityHash ('a' * 64) -OneDriveProcessRunning $true -ReceiptAttributeValue 0 -TaskEvidenceProvider { [pscustomobject]@{ TaskState='Ready'; LastTaskResult=0 } }
    $sameMachineRejected = $false
    try { $null = Get-AmmarTradingReportingAcceptanceEvidence -VpsName 'Demo VPS' -ExpectedAccountNumber $accounts -OneDriveRoot $oneDriveRoot -VpsEvidencePath $vpsEvidencePath } catch { $sameMachineRejected = $true }
    if(-not $sameMachineRejected) { throw 'Reporting acceptance claimed physical receipt on the same machine as the VPS.' }

    Set-AmmarTradingAcceptanceTestContext -MachineIdentityHash ('b' * 64) -OneDriveProcessRunning $false -ReceiptAttributeValue 0 -TaskEvidenceProvider { [pscustomobject]@{ TaskState='Ready'; LastTaskResult=0 } }
    $stoppedOneDriveRejected = $false
    try { $null = Get-AmmarTradingReportingAcceptanceEvidence -VpsName 'Demo VPS' -ExpectedAccountNumber $accounts -OneDriveRoot $oneDriveRoot -VpsEvidencePath $vpsEvidencePath } catch { $stoppedOneDriveRejected = $true }
    if(-not $stoppedOneDriveRejected) { throw 'Reporting acceptance claimed physical receipt while OneDrive was not running.' }

    foreach($unhydratedAttribute in @([uint32]4096,[uint32]262144,[uint32]4194304)) {
        Set-AmmarTradingAcceptanceTestContext -MachineIdentityHash ('b' * 64) -OneDriveProcessRunning $true -ReceiptAttributeValue $unhydratedAttribute -TaskEvidenceProvider { [pscustomobject]@{ TaskState='Ready'; LastTaskResult=0 } }
        $recallRejected = $false
        try { $null = Get-AmmarTradingReportingAcceptanceEvidence -VpsName 'Demo VPS' -ExpectedAccountNumber $accounts -OneDriveRoot $oneDriveRoot -VpsEvidencePath $vpsEvidencePath } catch { $recallRejected = $true }
        if(-not $recallRejected) { throw "Reporting acceptance claimed physical receipt for offline/recall attribute $unhydratedAttribute." }
    }

    Set-AmmarTradingAcceptanceTestContext -MachineIdentityHash ('b' * 64) -OneDriveProcessRunning $true -ReceiptAttributeValue 0 -TaskEvidenceProvider { [pscustomobject]@{ TaskState='Ready'; LastTaskResult=0 } }
    $arbitraryRejected = $false
    try { $null = Get-AmmarTradingReportingAcceptanceEvidence -VpsName 'Demo VPS' -ExpectedAccountNumber $accounts -OneDriveRoot $arbitraryRoot -VpsEvidencePath $vpsEvidencePath } catch { $arbitraryRejected = $true }
    if(-not $arbitraryRejected) { throw 'Reporting acceptance trusted an arbitrary local folder as OneDrive.' }

    $uncRejected = $false
    try { $null = Get-AmmarTradingReportingAcceptanceEvidence -VpsName 'Demo VPS' -ExpectedAccountNumber $accounts -OneDriveRoot '\\server\share' -VpsEvidencePath $vpsEvidencePath } catch { $uncRejected = $true }
    if(-not $uncRejected) { throw 'Reporting acceptance accepted a UNC OneDrive root.' }

    $junctionTarget = Join-Path $fixtureRoot 'junction-target'
    $junctionRoot = Join-Path $fixtureRoot 'junction-root'
    New-Item -ItemType Directory -Path $junctionTarget | Out-Null
    New-Item -ItemType Junction -Path $junctionRoot -Target $junctionTarget | Out-Null
    $env:OneDrive = $junctionRoot
    $junctionRejected = $false
    try { $null = Get-AmmarTradingReportingAcceptanceEvidence -VpsName 'Demo VPS' -ExpectedAccountNumber $accounts -OneDriveRoot $junctionRoot -VpsEvidencePath $vpsEvidencePath } catch { $junctionRejected = $true }
    if(-not $junctionRejected) { throw 'Reporting acceptance accepted a junction OneDrive root.' }
    $env:OneDrive = $oneDriveRoot

    $setupModule = Get-Module MoneyMachineSyncSetup
    & $setupModule { $script:AmmarTradingDriveTypeResolver = { param([string]$Root) [IO.DriveType]::Network } }
    $mappedRejected = $false
    try { $null = Get-AmmarTradingVpsAcceptanceEvidence -VpsName 'Demo VPS' -ExpectedAccountNumber $accounts -OneDriveRoot $oneDriveRoot -ConfigPath $configPath } catch { $mappedRejected = $true }
    if(-not $mappedRejected) { throw 'VPS acceptance accepted a mapped/network volume.' }
    & $setupModule { $script:AmmarTradingDriveTypeResolver = { param([string]$Root) (New-Object IO.DriveInfo($Root)).DriveType } }

    $mismatchConfig = Join-Path $runtimeRoot 'mismatch.csv'
    @($mappings[0], [pscustomobject]@{ Enabled='true'; VpsName='Demo VPS'; ExpectedMT4Login='99999999'; SourceCsv=$mappings[1].SourceCsv; OneDriveRoot=$oneDriveRoot }) | Export-Csv -LiteralPath $mismatchConfig -NoTypeInformation -Encoding utf8
    $schemaMismatchRejected = $false
    try { $null = Get-AmmarTradingVpsAcceptanceEvidence -VpsName 'Demo VPS' -ExpectedAccountNumber @('10000001','99999999') -OneDriveRoot $oneDriveRoot -ConfigPath $mismatchConfig } catch { $schemaMismatchRejected = $true }
    if(-not $schemaMismatchRejected) { throw 'VPS acceptance accepted a source whose schema-v3 account identity differs from the expected account.' }

    $safeOutput = Join-Path $evidenceRoot 'new-evidence.json'
    Write-NewAmmarTradingAcceptanceEvidence -Path $safeOutput -Json '{"status":"pass"}' -OneDriveRoot $oneDriveRoot -ProtectedPaths (@($configPath) + @($mappings | ForEach-Object SourceCsv)) -InputPaths @($vpsEvidencePath)
    $collisionRejected = $false
    try { Write-NewAmmarTradingAcceptanceEvidence -Path $safeOutput -Json '{"status":"replacement"}' -OneDriveRoot $oneDriveRoot -ProtectedPaths @($configPath) -InputPaths @($vpsEvidencePath) } catch { $collisionRejected = $true }
    if(-not $collisionRejected -or (Get-Content -LiteralPath $safeOutput -Raw) -notmatch 'pass') { throw 'Acceptance evidence overwrote an existing evidence target.' }
    $oneDriveOutputRejected = $false
    try { Write-NewAmmarTradingAcceptanceEvidence -Path (Join-Path $oneDriveRoot 'evidence.json') -Json '{}' -OneDriveRoot $oneDriveRoot -ProtectedPaths @($configPath) } catch { $oneDriveOutputRejected = $true }
    if(-not $oneDriveOutputRejected) { throw 'Acceptance evidence was written inside OneDrive.' }
    $overlapRejected = $false
    try { Write-NewAmmarTradingAcceptanceEvidence -Path (Join-Path $sourceRoot 'evidence.json') -Json '{}' -OneDriveRoot $oneDriveRoot -ProtectedPaths (@($configPath) + @($mappings | ForEach-Object SourceCsv)) } catch { $overlapRejected = $true }
    if(-not $overlapRejected) { throw 'Acceptance evidence was written beside protected source CSV data.' }
    if(@(Get-ChildItem -LiteralPath $evidenceRoot -Filter '*.tmp' -Force -ErrorAction SilentlyContinue).Count -ne 0) { throw 'Acceptance evidence left an atomic-write temporary file.' }

    $duplicate = @($mappings + $mappings[0])
    $duplicate | Export-Csv -LiteralPath $configPath -NoTypeInformation -Encoding utf8
    $duplicateRejected = $false
    try {
        $null = Get-AmmarTradingVpsAcceptanceEvidence -VpsName 'Demo VPS' -ExpectedAccountNumber $accounts -OneDriveRoot $oneDriveRoot -ConfigPath $configPath
    } catch { $duplicateRejected = $true }
    if(-not $duplicateRejected) { throw 'VPS evidence accepted duplicate mappings for one selected account.' }

    $sourcePath = 'C:\PrivateSource\AGOLD___Baskets.csv'
    $configurationSecret = 'OneDriveCredential=acceptance-secret'
    $report = [ordered]@{
        StartedUtc = [DateTime]::UtcNow.ToString('o')
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        Runtime = [ordered]@{
            PowerShell = '5.1'
            Computer = [Environment]::MachineName
            PersonalPath = 'C:\Users\Private Person\OneDrive\MoneyMachine'
        }
        Checks = @([ordered]@{
            Name = 'redaction-contract'
            Status = 'Pass'
            StartedUtc = [DateTime]::UtcNow.ToString('o')
            CompletedUtc = [DateTime]::UtcNow.ToString('o')
            Message = "Validated $sourcePath; $configurationSecret"
            Artifacts = @([ordered]@{ Name='fixture'; Sha256=('a' * 64) })
        })
        OverallStatus = 'Pass'
    }

    $json = ConvertTo-RedactedAcceptanceJson -Report $report -SensitiveValues @($sourcePath,$configurationSecret)
    foreach($forbidden in @('C:\Users\','Private Person',[Environment]::MachineName,$sourcePath,$configurationSecret,'acceptance-secret')) {
        if($json -match [regex]::Escape($forbidden)) { throw "Acceptance JSON leaked forbidden text: $forbidden" }
    }
    $parsed = $json | ConvertFrom-Json
    if($parsed.OverallStatus -ne 'Pass' -or @($parsed.Checks).Count -ne 1) { throw 'Acceptance JSON does not preserve the documented result schema.' }
    if(@($parsed.Checks[0].Artifacts).Count -ne 1) { throw 'Acceptance JSON must preserve Artifacts as an array.' }
    if($parsed.Checks[0].Artifacts[0].Sha256 -ne ('a' * 64)) { throw 'Acceptance JSON did not preserve the artifact hash.' }

    $outputPath = Join-Path $tempRoot 'audit\windows-production-acceptance.json'
    Write-AtomicAcceptanceReport -Path $outputPath -Json $json
    $saved = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
    if($saved.OverallStatus -ne 'Pass') { throw 'Atomically written acceptance JSON could not be parsed.' }
    if(@(Get-ChildItem -LiteralPath (Split-Path -Parent $outputPath) -Filter '*.tmp' -ErrorAction SilentlyContinue).Count -ne 0) {
        throw 'Atomic acceptance output left a temporary file behind.'
    }

    Write-Host 'Windows production acceptance contract passed.'
}
finally {
    if($null -ne $oldOneDrive) { $env:OneDrive=$oldOneDrive } else { Remove-Item Env:\OneDrive -ErrorAction SilentlyContinue }
    if(Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
