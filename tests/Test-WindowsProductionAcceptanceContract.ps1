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
try {
    . $RunnerPath -StagingRoot $tempRoot -AsLibrary

    $fixtureRoot = Join-Path $tempRoot 'e2e-fixture'
    $oneDriveRoot = Join-Path $fixtureRoot 'OneDrive'
    $runtimeRoot = Join-Path $fixtureRoot 'runtime'
    $sourceRoot = Join-Path $fixtureRoot 'sources'
    New-Item -ItemType Directory -Path $oneDriveRoot,$runtimeRoot,$sourceRoot -Force | Out-Null
    $accounts = @('10000001','10000002')
    $mappings = [Collections.Generic.List[object]]::new()
    foreach($account in $accounts) {
        $source = Join-Path $sourceRoot "$account.csv"
        $destinationRoot = Join-Path $oneDriveRoot "AmmarTrading\Account_$account"
        New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
        $destination = Join-Path $destinationRoot 'Baskets.csv'
        [IO.File]::WriteAllText($source,"fixture-$account",[Text.UTF8Encoding]::new($false))
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

    $vpsEvidence = Get-AmmarTradingVpsAcceptanceEvidence -VpsName 'Demo VPS' -ExpectedAccountNumber $accounts -OneDriveRoot $oneDriveRoot -ConfigPath $configPath -TaskEvidenceProvider {
        [pscustomobject]@{ TaskState='Ready'; LastTaskResult=0 }
    }
    if($vpsEvidence.EvidenceRole -cne 'Vps' -or [bool]$vpsEvidence.CloudDeliveryVerified) {
        throw 'VPS evidence must be explicitly role-bound and must never claim cloud delivery.'
    }
    if(@($vpsEvidence.Accounts).Count -ne 2 -or @($vpsEvidence.Accounts | Where-Object { $_.SourceHash -cne $_.DestinationHash }).Count -ne 0) {
        throw 'VPS evidence must prove exactly two independently hash-matched account publications.'
    }

    $vpsEvidencePath = Join-Path $fixtureRoot 'vps-evidence.json'
    Write-AtomicAcceptanceReport -Path $vpsEvidencePath -Json ($vpsEvidence | ConvertTo-Json -Depth 8)
    $reportingEvidence = Get-AmmarTradingReportingAcceptanceEvidence -VpsName 'Demo VPS' -ExpectedAccountNumber $accounts -OneDriveRoot $oneDriveRoot -VpsEvidencePath $vpsEvidencePath
    if($reportingEvidence.EvidenceRole -cne 'ReportingPc' -or -not [bool]$reportingEvidence.CloudDeliveryVerified) {
        throw 'Only reporting-PC evidence may set CloudDeliveryVerified after physical local hash checks.'
    }

    $duplicate = @($mappings + $mappings[0])
    $duplicate | Export-Csv -LiteralPath $configPath -NoTypeInformation -Encoding utf8
    $duplicateRejected = $false
    try {
        $null = Get-AmmarTradingVpsAcceptanceEvidence -VpsName 'Demo VPS' -ExpectedAccountNumber $accounts -OneDriveRoot $oneDriveRoot -ConfigPath $configPath -TaskEvidenceProvider {
            [pscustomobject]@{ TaskState='Ready'; LastTaskResult=0 }
        }
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
    if(Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
