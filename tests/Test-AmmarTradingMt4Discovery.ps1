[CmdletBinding()]
param(
    [string]$SetupModulePath,
    [string]$SchemaModulePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if([string]::IsNullOrWhiteSpace($SetupModulePath)) {
    $SetupModulePath = Join-Path $PSScriptRoot '..\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1'
}
if([string]::IsNullOrWhiteSpace($SchemaModulePath)) {
    $SchemaModulePath = Join-Path $PSScriptRoot '..\automation\MoneyMachineCsvSync\MoneyMachineCsvSchemaV3.psm1'
}

$TestDrive = Join-Path ([IO.Path]::GetTempPath()) ("AmmarTradingMt4DiscoveryTest_" + [guid]::NewGuid().ToString('N'))

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if(-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual,$Expected,[string]$Message)
    if($Actual -cne $Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
}

function Copy-DiscoveryFixture {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$AccountNumber,
        [Parameter(Mandatory)][string]$BrokerName,
        [string]$SchemaVersion = '3'
    )

    $rows = @(Import-Csv -LiteralPath (Join-Path $PSScriptRoot 'fixtures\AGOLD___Baskets_v3.csv'))
    $rows[0].AccountNumber = $AccountNumber
    $rows[0].BrokerName = $BrokerName
    $rows[0].CsvSchemaVersion = $SchemaVersion
    if($SchemaVersion -ceq '2') {
        $schemaV2Columns = @($rows[0].PSObject.Properties.Name[0..33]) + @('CsvSchemaVersion')
        $rows | Select-Object -Property $schemaV2Columns | Export-Csv -LiteralPath $Destination -NoTypeInformation -Encoding utf8
    } else {
        $rows | Export-Csv -LiteralPath $Destination -NoTypeInformation -Encoding utf8
    }
}

function Write-IdentityFixture {
    param(
        [Parameter(Mandatory)][string]$FilesDirectory,
        [Parameter(Mandatory)][string]$AccountNumber,
        [Parameter(Mandatory)][string]$BrokerName,
        [string]$SchemaVersion = '3',
        [string]$EaVersion = '3.00'
    )

    @(
        'AccountNumber,BrokerName,CsvSchemaVersion,EAVersion',
        ('{0},"{1}",{2},{3}' -f $AccountNumber,$BrokerName.Replace('"','""'),$SchemaVersion,$EaVersion)
    ) | Set-Content -LiteralPath (Join-Path $FilesDirectory 'AGOLD___Identity.csv') -Encoding utf8
}

function New-TerminalFixture {
    param(
        [Parameter(Mandatory)][string]$TerminalRoot,
        [Parameter(Mandatory)][string]$TerminalId,
        [Parameter(Mandatory)][ValidateSet('Ready','SchemaV2','HeaderOnly','MalformedCsv')][string]$Kind,
        [string]$AccountNumber = '892522910',
        [string]$BrokerName = 'FXCM',
        [string]$Origin,
        [switch]$WriteIdentity
    )

    $terminalDirectory = Join-Path $TerminalRoot $TerminalId
    $filesDirectory = Join-Path $terminalDirectory 'MQL4\Files'
    New-Item -ItemType Directory -Path $filesDirectory -Force | Out-Null
    $csv = Join-Path $filesDirectory 'AGOLD___Baskets.csv'
    switch($Kind) {
        'Ready' { Copy-DiscoveryFixture -Destination $csv -AccountNumber $AccountNumber -BrokerName $BrokerName }
        'SchemaV2' { Copy-DiscoveryFixture -Destination $csv -AccountNumber $AccountNumber -BrokerName $BrokerName -SchemaVersion '2' }
        'HeaderOnly' {
            $header = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\AGOLD___Baskets_v3.csv') -TotalCount 1
            Set-Content -LiteralPath $csv -Value $header -Encoding utf8
        }
        'MalformedCsv' {
            $header = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\AGOLD___Baskets_v3.csv') -TotalCount 1
            Set-Content -LiteralPath $csv -Value @($header,'broken,row') -Encoding utf8
        }
    }
    if($WriteIdentity) {
        Write-IdentityFixture -FilesDirectory $filesDirectory -AccountNumber $AccountNumber -BrokerName $BrokerName
    }
    if(-not [string]::IsNullOrWhiteSpace($Origin)) {
        Set-Content -LiteralPath (Join-Path $terminalDirectory 'origin.txt') -Value $Origin -Encoding utf8
    }
    return $csv
}

try {
    $terminalRoot = Join-Path $TestDrive 'MetaQuotes\Terminal'
    New-Item -ItemType Directory -Path $terminalRoot -Force | Out-Null

    $freshCsv = New-TerminalFixture -TerminalRoot $terminalRoot -TerminalId 'TERMINAL_A' -Kind Ready -AccountNumber '10000001' -BrokerName 'Broker Alpha' -Origin 'C:\Terminals\Alpha'
    $staleCsv = New-TerminalFixture -TerminalRoot $terminalRoot -TerminalId 'TERMINAL_B' -Kind Ready -AccountNumber '20000002' -BrokerName 'Broker Beta' -Origin 'C:\Terminals\Beta'
    [IO.File]::SetLastWriteTimeUtc($freshCsv, [DateTime]::UtcNow.AddMinutes(-5))
    [IO.File]::SetLastWriteTimeUtc($staleCsv, [DateTime]::UtcNow.AddMinutes(-20))

    [void](New-TerminalFixture -TerminalRoot $terminalRoot -TerminalId 'TERMINAL_V2' -Kind SchemaV2 -AccountNumber '30000003' -BrokerName 'Broker V2' -Origin 'C:\Terminals\V2')
    [void](New-TerminalFixture -TerminalRoot $terminalRoot -TerminalId 'TERMINAL_HEADER' -Kind HeaderOnly -Origin 'C:\Terminals\Header')
    [void](New-TerminalFixture -TerminalRoot $terminalRoot -TerminalId 'TERMINAL_HEADER_IDENTITY' -Kind HeaderOnly -AccountNumber '30000004' -BrokerName 'Broker Immediate' -Origin 'C:\Terminals\Immediate' -WriteIdentity)
    [void](New-TerminalFixture -TerminalRoot $terminalRoot -TerminalId 'TERMINAL_BAD' -Kind MalformedCsv -Origin 'C:\Terminals\Bad')
    [void](New-TerminalFixture -TerminalRoot $terminalRoot -TerminalId 'TERMINAL_DUP_A' -Kind Ready -AccountNumber '40000004' -BrokerName 'Broker Duplicate' -Origin 'C:\Terminals\DupA')
    [void](New-TerminalFixture -TerminalRoot $terminalRoot -TerminalId 'TERMINAL_DUP_B' -Kind Ready -AccountNumber '40000004' -BrokerName 'Broker Duplicate' -Origin 'C:\Terminals\DupB')
    [void](New-TerminalFixture -TerminalRoot $terminalRoot -TerminalId 'TERMINAL_INACTIVE' -Kind Ready -AccountNumber '70000007' -BrokerName 'Broker Inactive' -Origin 'C:\Terminals\Inactive')

    $nestedFiles = Join-Path $terminalRoot 'TERMINAL_PARENT\nested\MQL4\Files'
    New-Item -ItemType Directory -Path $nestedFiles -Force | Out-Null
    Copy-DiscoveryFixture -Destination (Join-Path $nestedFiles 'AGOLD___Baskets.csv') -AccountNumber '50000005' -BrokerName 'Nested Decoy'

    $manualDirectory = Join-Path $TestDrive 'Manual'
    New-Item -ItemType Directory -Path $manualDirectory -Force | Out-Null
    $manualCsv = Join-Path $manualDirectory 'selected-report.csv'
    Copy-DiscoveryFixture -Destination $manualCsv -AccountNumber '60000006' -BrokerName 'Manual Broker'

    Import-Module -Name $SetupModulePath -Force -ErrorAction Stop
    Import-Module -Name $SchemaModulePath -Force -ErrorAction Stop

    $setupSource = Get-Content -LiteralPath $SetupModulePath -Raw
    Assert-True -Condition ($setupSource -match "\[Diagnostics\.Process\]::GetProcessesByName\('terminal'\)") -Message 'Automatic discovery must enumerate running MT4 processes without depending on the optional WMI repository.'

    $setupModule = Get-Module -Name MoneyMachineSyncSetup
    & $setupModule {
        $script:AmmarTradingRunningTerminalPathResolver = {
            @(
                'C:\Terminals\Alpha\terminal.exe','C:\Terminals\Beta\terminal.exe','C:\Terminals\V2\terminal.exe',
                'C:\Terminals\Header\terminal.exe','C:\Terminals\Immediate\terminal.exe','C:\Terminals\Bad\terminal.exe',
                'C:\Terminals\DupA\terminal.exe','C:\Terminals\DupB\terminal.exe'
            )
        }
    }

    $accounts = @(Get-AmmarTradingMt4Accounts -TerminalDataRoot $terminalRoot)
    $ready = @($accounts | Where-Object Eligibility -eq 'Ready')
    Assert-Equal -Actual $ready.Count -Expected 3 -Message 'Discovery must return two completed accounts and one sidecar-identified header-only account.'
    Assert-True -Condition ($ready[0].AccountNumber -match '^\d+$') -Message 'A ready account must expose a digit-only account number.'
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$ready[0].BrokerName)) -Message 'A ready account must expose a broker name.'
    Assert-True -Condition ($ready[0].DiscoveryId -cmatch '^[A-F0-9]{64}$') -Message 'A discovery identity must be an uppercase SHA-256 value.'
    Assert-Equal -Actual @($accounts | Where-Object ReasonCode -eq 'SchemaV2').Count -Expected 1 -Message 'Schema-v2 sources must be classified explicitly.'
    Assert-Equal -Actual @($accounts | Where-Object ReasonCode -eq 'HeaderOnly').Count -Expected 1 -Message 'Header-only sources must remain visible and blocked.'
    Assert-Equal -Actual @($accounts | Where-Object ReasonCode -eq 'MalformedCsv').Count -Expected 1 -Message 'Malformed sources must remain visible and blocked.'
    Assert-Equal -Actual @($accounts | Where-Object ReasonCode -eq 'DuplicateAccount').Count -Expected 2 -Message 'Every source in an account conflict must be blocked.'
    Assert-Equal -Actual @($accounts | Where-Object AccountNumber -eq '30000004' | Where-Object ReasonCode -eq 'Ready').Count -Expected 1 -Message 'A schema-v3 header-only source with a matching immediate identity sidecar must be ready.'
    Assert-Equal -Actual @($accounts | Where-Object AccountNumber -eq '70000007').Count -Expected 0 -Message 'A report from an inactive MT4 terminal must not appear in automatic discovery.'
    Assert-Equal -Actual @($accounts | Where-Object AccountNumber -eq '50000005').Count -Expected 0 -Message 'Discovery must not recurse below direct terminal directories.'
    $legacyDiscovery = Get-MoneyMachineSetupDiscovery -OneDriveCandidates @() -TerminalDataRoot $terminalRoot
    Assert-Equal -Actual @($legacyDiscovery.Sources | Where-Object Path -eq (Join-Path $nestedFiles 'AGOLD___Baskets.csv')).Count -Expected 0 -Message 'The compatibility discovery surface must use the same direct-location boundary.'
    Assert-Equal -Actual @($legacyDiscovery.Sources | Where-Object Path -eq (Join-Path $terminalRoot 'TERMINAL_INACTIVE\MQL4\Files\AGOLD___Baskets.csv')).Count -Expected 0 -Message 'The compatibility discovery surface must exclude inactive MT4 terminal roots.'

    $fresh = @($accounts | Where-Object AccountNumber -eq '10000001')[0]
    $stale = @($accounts | Where-Object AccountNumber -eq '20000002')[0]
    $freshFile = Get-Item -LiteralPath $fresh.SourceCsv
    $expectedFingerprint = Get-AmmarTradingDiscoveryFingerprint -SourceCsv $freshFile.FullName -AccountNumber '10000001'
    $fingerprintFile = Join-Path $TestDrive 'expected-fingerprint.txt'
    [IO.File]::WriteAllText($fingerprintFile, $expectedFingerprint, (New-Object Text.UTF8Encoding($false)))
    Assert-Equal -Actual $fresh.DiscoveryId -Expected (Get-FileHash -LiteralPath $fingerprintFile -Algorithm SHA256).Hash -Message 'DiscoveryId must hash the canonical path, account, volume serial, and file index.'
    $freshFile.LastWriteTimeUtc = $freshFile.LastWriteTimeUtc.AddMinutes(1)
    $refreshed = @(Get-AmmarTradingMt4Accounts -TerminalDataRoot $terminalRoot | Where-Object AccountNumber -eq '10000001')[0]
    Assert-Equal -Actual $refreshed.DiscoveryId -Expected $fresh.DiscoveryId -Message 'DiscoveryId must remain stable when MT4 rewrites the same source file.'
    Assert-Equal -Actual $fresh.TerminalName -Expected 'C:\Terminals\Alpha' -Message 'origin.txt must supply the terminal name when present.'
    Assert-Equal -Actual $fresh.Freshness -Expected 'Fresh' -Message 'A file no more than 15 minutes old must be fresh.'
    Assert-Equal -Actual $stale.Freshness -Expected 'Stale' -Message 'A file over 15 minutes old must be stale.'
    Assert-Equal -Actual ($accounts[0].PSObject.Properties.Name -join ',') -Expected 'DiscoveryId,AccountNumber,BrokerName,TerminalId,TerminalName,SourceCsv,SchemaVersion,LastWriteUtc,Freshness,Eligibility,ReasonCode' -Message 'Discovery results must preserve the public field contract and order.'

    $manualAccounts = @(Get-AmmarTradingMt4Accounts -TerminalDataRoot $terminalRoot -ManualCsv @($manualCsv))
    $manual = @($manualAccounts | Where-Object AccountNumber -eq '60000006')
    Assert-Equal -Actual $manual.Count -Expected 1 -Message 'An explicitly selected CSV outside an MT4 root must be discovered.'
    Assert-Equal -Actual $manual[0].TerminalId -Expected 'Manual' -Message 'Manual CSV discovery must use a stable terminal identifier.'
    Assert-Equal -Actual $manual[0].Eligibility -Expected 'Ready' -Message 'Manual browse must use the same identity validation as MT4 discovery.'

    & $setupModule {
        $script:AmmarTradingDriveTypeResolver = { param([string]$Root) [IO.DriveType]::Network }
    }
    try {
        $mappedTerminalAccounts = @(Get-AmmarTradingMt4Accounts -TerminalDataRoot $terminalRoot)
        Assert-Equal -Actual $mappedTerminalAccounts.Count -Expected 0 -Message 'A terminal root on a mapped network drive must not produce discovery candidates.'
        $mappedManualAccounts = @(Get-AmmarTradingMt4Accounts -TerminalDataRoot (Join-Path $TestDrive 'missing-terminal-root') -ManualCsv @($manualCsv))
        Assert-Equal -Actual $mappedManualAccounts.Count -Expected 0 -Message 'A manual CSV on a mapped network drive must not become eligible.'
        $mappedCompatibilityDiscovery = Get-MoneyMachineSetupDiscovery -OneDriveCandidates @() -TerminalDataRoot $terminalRoot
        Assert-Equal -Actual @($mappedCompatibilityDiscovery.Sources).Count -Expected 0 -Message 'Compatibility discovery must reject a mapped network terminal root.'
        $mappedSetupRejected = $false
        try {
            Test-MoneyMachineSetupRequest -VpsName 'Network source' -ExpectedMT4Login '10000001' -SourceCsv $freshCsv -OneDriveRoot $manualDirectory | Out-Null
        } catch {
            if($_.Exception.Message -notmatch 'local filesystem') { throw }
            $mappedSetupRejected = $true
        }
        Assert-True -Condition $mappedSetupRejected -Message 'Setup validation must reject a source on a mapped network drive.'
    } finally {
        Import-Module -Name $SetupModulePath -Force -ErrorAction Stop
    }

    $uncSource = '\\localhost\AmmarTradingMissingShare\AGOLD___Baskets.csv'
    $uncAccounts = @(Get-AmmarTradingMt4Accounts -TerminalDataRoot '\\localhost\AmmarTradingMissingShare' -ManualCsv @($uncSource))
    Assert-Equal -Actual $uncAccounts.Count -Expected 0 -Message 'UNC terminal and manual paths must not produce discovery candidates.'
    $uncSetupRejected = $false
    try {
        Test-MoneyMachineSetupRequest -VpsName 'UNC source' -ExpectedMT4Login '10000001' -SourceCsv $uncSource -OneDriveRoot $manualDirectory | Out-Null
    } catch {
        if($_.Exception.Message -notmatch 'local filesystem') { throw }
        $uncSetupRejected = $true
    }
    Assert-True -Condition $uncSetupRejected -Message 'Setup validation must reject UNC syntax before checking reachability.'

    $identity = Get-AmmarTradingCsvIdentity -Path $freshCsv
    Assert-Equal -Actual ($identity.PSObject.Properties.Name -join ',') -Expected 'AccountNumber,BrokerName,SchemaVersion,Status' -Message 'The bounded identity probe must return only identity and status metadata.'
    Assert-Equal -Actual $identity.Status -Expected 'Ready' -Message 'The bounded probe must accept a complete schema-v3 identity row.'

    $boundedCsv = Join-Path $manualDirectory 'bounded.csv'
    $validContent = Get-Content -LiteralPath $freshCsv
    Set-Content -LiteralPath $boundedCsv -Value @($validContent[0],$validContent[1],'bad,row') -Encoding utf8
    $boundedIdentity = Get-AmmarTradingCsvIdentity -Path $boundedCsv
    Assert-Equal -Actual $boundedIdentity.Status -Expected 'Ready' -Message 'Identity discovery must stop after the first complete data row.'
    $strictRejected = $false
    try { Read-MoneyMachineBasketsCsv -Path $boundedCsv -ExpectedLogin '10000001' | Out-Null } catch { $strictRejected = $true }
    Assert-True -Condition $strictRejected -Message 'The strict full-file schema validator must still reject a malformed later row.'

    Write-Host 'AmmarTrading MT4 account discovery tests passed.'
}
finally {
    if(Test-Path -LiteralPath $TestDrive) { Remove-Item -LiteralPath $TestDrive -Recurse -Force }
}
