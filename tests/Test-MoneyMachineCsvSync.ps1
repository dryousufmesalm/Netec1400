[CmdletBinding()]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot '..\automation\MoneyMachineCsvSync\Sync-BasketsToOneDrive.ps1')
)

$ErrorActionPreference = 'Stop'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("MoneyMachineCsvSyncTest_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    $sourceDir = Join-Path $tempRoot 'source'
    $oneDrive = Join-Path $tempRoot 'oneDrive'
    New-Item -ItemType Directory -Path $sourceDir,$oneDrive | Out-Null
    $sourceCsv = Join-Path $sourceDir 'AGOLD___Baskets.csv'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\AGOLD___Baskets_v3.csv') -Destination $sourceCsv

    $testConfigPath = Join-Path $tempRoot 'accounts.csv'
    @([pscustomobject]@{
        Enabled = 'true'
        ExpectedMT4Login = '892522910'
        SourceCsv = $sourceCsv
        OneDriveRoot = $oneDrive
    }) | Export-Csv -LiteralPath $testConfigPath -NoTypeInformation -Encoding utf8

    . $ScriptPath -AsLibrary
    $result = @(Invoke-MoneyMachineCsvSync -ConfigPath $testConfigPath -StableCheckSeconds 0 -MaxRetries 1)
    if($result.Count -ne 1 -or $result[0].Status -ne 'Success') { throw "Expected successful copy, got: $($result | ConvertTo-Json -Compress)" }

    $destination = Join-Path $oneDrive 'MoneyMachine\Account_892522910\Baskets.csv'
    if(-not (Test-Path -LiteralPath $destination)) { throw 'Destination CSV was not created.' }
    if((Get-Content -LiteralPath $destination -Raw) -notmatch 'RunStartBalance') { throw 'Destination CSV does not contain schema-v3 header.' }

    Add-Content -LiteralPath $sourceCsv -Value '# second copy replaces the existing destination'
    $second = @(Invoke-MoneyMachineCsvSync -ConfigPath $testConfigPath -StableCheckSeconds 0 -MaxRetries 1)
    if($second[0].Status -ne 'Success') { throw 'Second overwrite copy failed.' }
    if((Get-Content -LiteralPath $destination -Raw) -notmatch 'second copy replaces') { throw 'Destination was not overwritten.' }

    @([pscustomobject]@{ Enabled='true'; ExpectedMT4Login='999'; SourceCsv=$sourceCsv; OneDriveRoot=$oneDrive }) |
        Export-Csv -LiteralPath $testConfigPath -NoTypeInformation -Encoding utf8
    $mismatch = @(Invoke-MoneyMachineCsvSync -ConfigPath $testConfigPath -StableCheckSeconds 0 -MaxRetries 1)
    if($mismatch[0].Status -ne 'Skipped') { throw 'Account-login mismatch must be skipped.' }
    if((Get-Content -LiteralPath $destination -Raw) -notmatch 'second copy replaces') { throw 'A mismatch overwrote a valid destination.' }

    Write-Host 'MoneyMachine CSV sync tests passed.'
}
finally {
    if(Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
