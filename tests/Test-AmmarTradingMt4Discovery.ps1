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

function New-TerminalFixture {
    param(
        [Parameter(Mandatory)][string]$TerminalRoot,
        [Parameter(Mandatory)][string]$TerminalId,
        [Parameter(Mandatory)][ValidateSet('Ready','SchemaV2','HeaderOnly','MalformedCsv')][string]$Kind,
        [string]$AccountNumber = '892522910',
        [string]$BrokerName = 'FXCM',
        [string]$Origin
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
    if(-not [string]::IsNullOrWhiteSpace($Origin)) {
        Set-Content -LiteralPath (Join-Path $terminalDirectory 'origin.txt') -Value $Origin -Encoding utf8
    }
    return $csv
}

try {
    $terminalRoot = Join-Path $TestDrive 'MetaQuotes\Terminal'
    New-Item -ItemType Directory -Path $terminalRoot -Force | Out-Null

    $freshCsv = New-TerminalFixture -TerminalRoot $terminalRoot -TerminalId 'TERMINAL_A' -Kind Ready -AccountNumber '10000001' -BrokerName 'Broker Alpha' -Origin 'Broker Alpha MT4'
    $staleCsv = New-TerminalFixture -TerminalRoot $terminalRoot -TerminalId 'TERMINAL_B' -Kind Ready -AccountNumber '20000002' -BrokerName 'Broker Beta'
    [IO.File]::SetLastWriteTimeUtc($freshCsv, [DateTime]::UtcNow.AddMinutes(-5))
    [IO.File]::SetLastWriteTimeUtc($staleCsv, [DateTime]::UtcNow.AddMinutes(-20))

    [void](New-TerminalFixture -TerminalRoot $terminalRoot -TerminalId 'TERMINAL_V2' -Kind SchemaV2 -AccountNumber '30000003' -BrokerName 'Broker V2')
    [void](New-TerminalFixture -TerminalRoot $terminalRoot -TerminalId 'TERMINAL_HEADER' -Kind HeaderOnly)
    [void](New-TerminalFixture -TerminalRoot $terminalRoot -TerminalId 'TERMINAL_BAD' -Kind MalformedCsv)
    [void](New-TerminalFixture -TerminalRoot $terminalRoot -TerminalId 'TERMINAL_DUP_A' -Kind Ready -AccountNumber '40000004' -BrokerName 'Broker Duplicate')
    [void](New-TerminalFixture -TerminalRoot $terminalRoot -TerminalId 'TERMINAL_DUP_B' -Kind Ready -AccountNumber '40000004' -BrokerName 'Broker Duplicate')

    $nestedFiles = Join-Path $terminalRoot 'TERMINAL_PARENT\nested\MQL4\Files'
    New-Item -ItemType Directory -Path $nestedFiles -Force | Out-Null
    Copy-DiscoveryFixture -Destination (Join-Path $nestedFiles 'AGOLD___Baskets.csv') -AccountNumber '50000005' -BrokerName 'Nested Decoy'

    $manualDirectory = Join-Path $TestDrive 'Manual'
    New-Item -ItemType Directory -Path $manualDirectory -Force | Out-Null
    $manualCsv = Join-Path $manualDirectory 'selected-report.csv'
    Copy-DiscoveryFixture -Destination $manualCsv -AccountNumber '60000006' -BrokerName 'Manual Broker'

    Import-Module -Name $SetupModulePath -Force -ErrorAction Stop
    Import-Module -Name $SchemaModulePath -Force -ErrorAction Stop

    $accounts = @(Get-AmmarTradingMt4Accounts -TerminalDataRoot $terminalRoot)
    $ready = @($accounts | Where-Object Eligibility -eq 'Ready')
    Assert-Equal -Actual $ready.Count -Expected 2 -Message 'Discovery must return two unique ready accounts.'
    Assert-True -Condition ($ready[0].AccountNumber -match '^\d+$') -Message 'A ready account must expose a digit-only account number.'
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$ready[0].BrokerName)) -Message 'A ready account must expose a broker name.'
    Assert-True -Condition ($ready[0].DiscoveryId -cmatch '^[A-F0-9]{64}$') -Message 'A discovery identity must be an uppercase SHA-256 value.'
    Assert-Equal -Actual @($accounts | Where-Object ReasonCode -eq 'SchemaV2').Count -Expected 1 -Message 'Schema-v2 sources must be classified explicitly.'
    Assert-Equal -Actual @($accounts | Where-Object ReasonCode -eq 'HeaderOnly').Count -Expected 1 -Message 'Header-only sources must remain visible and blocked.'
    Assert-Equal -Actual @($accounts | Where-Object ReasonCode -eq 'MalformedCsv').Count -Expected 1 -Message 'Malformed sources must remain visible and blocked.'
    Assert-Equal -Actual @($accounts | Where-Object ReasonCode -eq 'DuplicateAccount').Count -Expected 2 -Message 'Every source in an account conflict must be blocked.'
    Assert-Equal -Actual @($accounts | Where-Object AccountNumber -eq '50000005').Count -Expected 0 -Message 'Discovery must not recurse below direct terminal directories.'
    $legacyDiscovery = Get-MoneyMachineSetupDiscovery -OneDriveCandidates @() -TerminalDataRoot $terminalRoot
    Assert-Equal -Actual @($legacyDiscovery.Sources | Where-Object Path -eq (Join-Path $nestedFiles 'AGOLD___Baskets.csv')).Count -Expected 0 -Message 'The compatibility discovery surface must use the same direct-location boundary.'

    $fresh = @($accounts | Where-Object AccountNumber -eq '10000001')[0]
    $stale = @($accounts | Where-Object AccountNumber -eq '20000002')[0]
    $freshFile = Get-Item -LiteralPath $fresh.SourceCsv
    $expectedFingerprint = '{0}|{1}|{2}|{3}' -f $freshFile.FullName,'10000001',$freshFile.Length,$freshFile.LastWriteTimeUtc.Ticks
    $fingerprintFile = Join-Path $TestDrive 'expected-fingerprint.txt'
    [IO.File]::WriteAllText($fingerprintFile, $expectedFingerprint, (New-Object Text.UTF8Encoding($false)))
    Assert-Equal -Actual $fresh.DiscoveryId -Expected (Get-FileHash -LiteralPath $fingerprintFile -Algorithm SHA256).Hash -Message 'DiscoveryId must hash the canonical path, account, length, and UTC write ticks in order.'
    Assert-Equal -Actual $fresh.TerminalName -Expected 'Broker Alpha MT4' -Message 'origin.txt must supply the terminal name when present.'
    Assert-Equal -Actual $fresh.Freshness -Expected 'Fresh' -Message 'A file no more than 15 minutes old must be fresh.'
    Assert-Equal -Actual $stale.Freshness -Expected 'Stale' -Message 'A file over 15 minutes old must be stale.'
    Assert-Equal -Actual ($accounts[0].PSObject.Properties.Name -join ',') -Expected 'DiscoveryId,AccountNumber,BrokerName,TerminalId,TerminalName,SourceCsv,SchemaVersion,LastWriteUtc,Freshness,Eligibility,ReasonCode' -Message 'Discovery results must preserve the public field contract and order.'

    $manualAccounts = @(Get-AmmarTradingMt4Accounts -TerminalDataRoot $terminalRoot -ManualCsv @($manualCsv))
    $manual = @($manualAccounts | Where-Object AccountNumber -eq '60000006')
    Assert-Equal -Actual $manual.Count -Expected 1 -Message 'An explicitly selected CSV outside an MT4 root must be discovered.'
    Assert-Equal -Actual $manual[0].TerminalId -Expected 'Manual' -Message 'Manual CSV discovery must use a stable terminal identifier.'
    Assert-Equal -Actual $manual[0].Eligibility -Expected 'Ready' -Message 'Manual browse must use the same identity validation as MT4 discovery.'

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
