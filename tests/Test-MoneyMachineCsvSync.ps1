[CmdletBinding()]
param(
    [string]$ScriptPath
)

$ErrorActionPreference = 'Stop'
if([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $ScriptPath = Join-Path $PSScriptRoot '..\automation\MoneyMachineCsvSync\Sync-BasketsToOneDrive.ps1'
}
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("MoneyMachineCsvSyncTest_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    $escapedScriptPath = $ScriptPath.Replace("'", "''")
    $libraryProbe = ". '$escapedScriptPath' -AsLibrary"
    $encodedProbe = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($libraryProbe))
    $libraryProcess = Start-Process -FilePath $windowsPowerShell -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encodedProbe) -Wait -PassThru
    if($libraryProcess.ExitCode -ne 0) { throw "Library import without ConfigPath exited $($libraryProcess.ExitCode)." }

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

    $updatedRows = @(Import-Csv -LiteralPath $sourceCsv)
    $updatedRows[0].BrokerName = 'second copy replaces the existing destination'
    $updatedRows | Export-Csv -LiteralPath $sourceCsv -NoTypeInformation -Encoding utf8
    $second = @(Invoke-MoneyMachineCsvSync -ConfigPath $testConfigPath -StableCheckSeconds 0 -MaxRetries 1)
    if($second[0].Status -ne 'Success') { throw 'Second overwrite copy failed.' }
    if((Get-Content -LiteralPath $destination -Raw) -notmatch 'second copy replaces') { throw 'Destination was not overwritten.' }

    @([pscustomobject]@{ Enabled='true'; ExpectedMT4Login='999'; SourceCsv=$sourceCsv; OneDriveRoot=$oneDrive }) |
        Export-Csv -LiteralPath $testConfigPath -NoTypeInformation -Encoding utf8
    $mismatch = @(Invoke-MoneyMachineCsvSync -ConfigPath $testConfigPath -StableCheckSeconds 0 -MaxRetries 1)
    if($mismatch[0].Status -ne 'Error') { throw 'Account-login mismatch must return Error.' }
    if((Get-Content -LiteralPath $destination -Raw) -notmatch 'second copy replaces') { throw 'A mismatch overwrote a valid destination.' }

    @([pscustomobject]@{ Enabled='true'; ExpectedMT4Login='892522910'; SourceCsv=$sourceCsv; OneDriveRoot=$oneDrive }) |
        Export-Csv -LiteralPath $testConfigPath -NoTypeInformation -Encoding utf8
    $header = Get-Content -LiteralPath $sourceCsv -TotalCount 1
    Set-Content -LiteralPath $sourceCsv -Value $header -Encoding utf8
    $headerOnly = @(Invoke-MoneyMachineCsvSync -ConfigPath $testConfigPath -StableCheckSeconds 0 -MaxRetries 1)
    if($headerOnly[0].Status -ne 'Success') { throw 'A valid schema-v3 header-only CSV must publish successfully.' }
    if(@(Import-Csv -LiteralPath $destination).Count -ne 0) { throw 'Header-only publication must contain zero data rows.' }

    Set-Content -LiteralPath $destination -Value 'known-good-destination' -Encoding utf8
    Set-Content -LiteralPath $sourceCsv -Value @($header, 'bad,row') -Encoding utf8
    $malformed = @(Invoke-MoneyMachineCsvSync -ConfigPath $testConfigPath -StableCheckSeconds 0 -MaxRetries 1)
    if($malformed[0].Status -ne 'Error') { throw 'Malformed CSV must return Error.' }
    if((Get-Content -LiteralPath $destination -Raw) -ne "known-good-destination`r`n") { throw 'Malformed CSV must preserve the previous destination.' }

    $missingConfig = Join-Path $tempRoot 'missing.csv'
    @([pscustomobject]@{ Enabled='true'; ExpectedMT4Login='892522910'; SourceCsv=(Join-Path $tempRoot 'does-not-exist.csv'); OneDriveRoot=$oneDrive }) |
        Export-Csv -LiteralPath $missingConfig -NoTypeInformation -Encoding utf8
    $missing = @(Invoke-MoneyMachineCsvSync -ConfigPath $missingConfig -StableCheckSeconds 0 -MaxRetries 1)
    if($missing[0].Status -ne 'Error') { throw 'An enabled missing source must return Error.' }

    $missingProcess = Start-Process -FilePath $windowsPowerShell -ArgumentList @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
        '-File',('"{0}"' -f $ScriptPath),
        '-ConfigPath',('"{0}"' -f $missingConfig),
        '-StableCheckSeconds','0','-MaxRetries','1'
    ) -Wait -PassThru
    if($missingProcess.ExitCode -eq 0) { throw 'An enabled missing source must return a nonzero process exit code.' }

    Write-Host 'MoneyMachine CSV sync tests passed.'
}
finally {
    if(Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
