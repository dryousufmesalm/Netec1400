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
    $runtimeRoot = Join-Path $tempRoot 'runtime'
    New-Item -ItemType Directory -Path $sourceDir,$oneDrive,$runtimeRoot | Out-Null
    $sourceCsv = Join-Path $sourceDir 'AGOLD___Baskets.csv'
    $fixturePath = Join-Path $PSScriptRoot 'fixtures\AGOLD___Baskets_v3.csv'
    Copy-Item -LiteralPath $fixturePath -Destination $sourceCsv

    $testConfigPath = Join-Path $tempRoot 'accounts.csv'
    @([pscustomobject]@{
        Enabled = 'true'
        ExpectedMT4Login = '892522910'
        SourceCsv = $sourceCsv
        OneDriveRoot = $oneDrive
    }) | Export-Csv -LiteralPath $testConfigPath -NoTypeInformation -Encoding utf8

    . $ScriptPath -AsLibrary
    $logDir = Join-Path $runtimeRoot 'logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $logDir 'sync.log'), (New-Object byte[] (5MB - 5)))
    Write-SyncLog -Level 'INFO' -Message ('x' * 100) -RuntimeRoot $runtimeRoot
    if(-not (Test-Path -LiteralPath (Join-Path $logDir 'sync.log.1'))) { throw 'A log that cannot fit the next line within 5 MiB must rotate before the write.' }
    if((Get-Item -LiteralPath (Join-Path $logDir 'sync.log')).Length -gt 5MB) { throw 'The active sync log must never exceed 5 MiB.' }

    $result = @(Invoke-MoneyMachineCsvSync -ConfigPath $testConfigPath -StableCheckSeconds 0 -MaxRetries 1 -RuntimeRoot $runtimeRoot)
    if($result.Count -ne 1 -or $result[0].Status -ne 'Success') { throw "Expected successful copy, got: $($result | ConvertTo-Json -Compress)" }

    $lastRunPath = Join-Path $runtimeRoot 'state\last-run.json'
    $lastRun = Get-Content -LiteralPath $lastRunPath -Raw | ConvertFrom-Json
    if($lastRun.OverallStatus -ne 'Success' -or -not $lastRun.StartedUtc -or -not $lastRun.CompletedUtc) { throw 'last-run.json must contain successful run timestamps and overall status.' }
    if(@($lastRun.Results).Count -ne 1 -or -not $lastRun.Accounts.'892522910') { throw 'last-run.json must contain result rows and per-account catch-up state.' }

    $destination = Join-Path $oneDrive 'MoneyMachine\Account_892522910\Baskets.csv'
    if(-not (Test-Path -LiteralPath $destination)) { throw 'Destination CSV was not created.' }
    if((Get-Content -LiteralPath $destination -Raw) -notmatch 'RunStartBalance') { throw 'Destination CSV does not contain schema-v3 header.' }

    $updatedRows = @(Import-Csv -LiteralPath $sourceCsv)
    $updatedRows[0].BrokerName = 'second copy replaces the existing destination'
    $updatedRows | Export-Csv -LiteralPath $sourceCsv -NoTypeInformation -Encoding utf8
    $second = @(Invoke-MoneyMachineCsvSync -ConfigPath $testConfigPath -StableCheckSeconds 0 -MaxRetries 1 -RuntimeRoot $runtimeRoot)
    if($second[0].Status -ne 'Success') { throw 'Second overwrite copy failed.' }
    if((Get-Content -LiteralPath $destination -Raw) -notmatch 'second copy replaces') { throw 'Destination was not overwritten.' }

    $baselineHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    $invalidCases = @(
        @{ Name='duplicate key'; Expected='duplicate'; Build={ $rows=@(Import-Csv -LiteralPath $fixturePath); @($rows[0],$rows[0]) } },
        @{ Name='direction enum'; Expected='Direction'; Build={ $rows=@(Import-Csv -LiteralPath $fixturePath); $rows[0].Direction='SIDEWAYS'; $rows } },
        @{ Name='duration type'; Expected='DurationSeconds'; Build={ $rows=@(Import-Csv -LiteralPath $fixturePath); $rows[0].DurationSeconds='not-an-integer'; $rows } },
        @{ Name='max orders type'; Expected='MaxOrdersInBasket'; Build={ $rows=@(Import-Csv -LiteralPath $fixturePath); $rows[0].MaxOrdersInBasket='not-an-integer'; $rows } },
        @{ Name='decimal type'; Expected='TotalLots'; Build={ $rows=@(Import-Csv -LiteralPath $fixturePath); $rows[0].TotalLots='not-a-decimal'; $rows } },
        @{ Name='boolean value'; Expected='UseBasketTrailingTP'; Build={ $rows=@(Import-Csv -LiteralPath $fixturePath); $rows[0].UseBasketTrailingTP='true'; $rows } },
        @{ Name='timestamp type'; Expected='StartTime'; Build={ $rows=@(Import-Csv -LiteralPath $fixturePath); $rows[0].StartTime='27/07/2026 03:00'; $rows } },
        @{ Name='end before start'; Expected='EndTime'; Build={ $rows=@(Import-Csv -LiteralPath $fixturePath); $rows[0].EndTime='2026-07-27 02:59:59'; $rows } },
        @{ Name='duration agreement'; Expected='DurationSeconds'; Build={ $rows=@(Import-Csv -LiteralPath $fixturePath); $rows[0].DurationSeconds='301'; $rows } },
        @{ Name='trade date agreement'; Expected='TradeDate'; Build={ $rows=@(Import-Csv -LiteralPath $fixturePath); $rows[0].TradeDate='1999-01-01'; $rows } },
        @{ Name='missing run key'; Expected='RunID'; Build={ $rows=@(Import-Csv -LiteralPath $fixturePath); $rows[0].RunID=''; $rows } },
        @{ Name='missing basket key'; Expected='BasketID'; Build={ $rows=@(Import-Csv -LiteralPath $fixturePath); $rows[0].BasketID=''; $rows } },
        @{ Name='mixed account'; Expected='AccountNumber'; Build={ $rows=@(Import-Csv -LiteralPath $fixturePath); $rows[0].AccountNumber='999'; $rows } },
        @{ Name='wrong schema'; Expected='CsvSchemaVersion'; Build={ $rows=@(Import-Csv -LiteralPath $fixturePath); $rows[0].CsvSchemaVersion='2'; $rows } }
    )
    foreach($case in $invalidCases) {
        @(& $case.Build) | Export-Csv -LiteralPath $sourceCsv -NoTypeInformation -Encoding utf8
        $invalid = @(Invoke-MoneyMachineCsvSync -ConfigPath $testConfigPath -StableCheckSeconds 0 -MaxRetries 1 -RuntimeRoot $runtimeRoot)
        if($invalid[0].Status -ne 'Error') { throw "Invalid case '$($case.Name)' must return Error." }
        if($invalid[0].Message -notmatch [regex]::Escape($case.Expected)) { throw "Invalid case '$($case.Name)' did not identify '$($case.Expected)': $($invalid[0].Message)" }
        if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $baselineHash) { throw "Invalid case '$($case.Name)' overwrote the valid destination." }
    }

    $legacyRows = @(Import-Csv -LiteralPath $fixturePath)
    $legacyRows[0].MaxOrdersInBasket = ''
    $legacyRows | Export-Csv -LiteralPath $sourceCsv -NoTypeInformation -Encoding utf8
    $legacyBlank = @(Invoke-MoneyMachineCsvSync -ConfigPath $testConfigPath -StableCheckSeconds 0 -MaxRetries 1 -RuntimeRoot $runtimeRoot)
    if($legacyBlank[0].Status -ne 'Success') { throw 'Legacy blank MaxOrdersInBasket must be accepted as disabled value 0.' }

    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\AGOLD___Baskets_v3_quoted.csv') -Destination $sourceCsv -Force
    $quoted = @(Invoke-MoneyMachineCsvSync -ConfigPath $testConfigPath -StableCheckSeconds 0 -MaxRetries 1 -RuntimeRoot $runtimeRoot)
    if($quoted[0].Status -ne 'Success' -or $quoted[0].RowCount -ne 1) { throw 'Quoted CSV fixture must publish as one logical row.' }
    $quotedRows = @(Import-Csv -LiteralPath $destination)
    if($quotedRows[0].BrokerName -ne 'Broker, "Gold" Desk') { throw 'Quoted BrokerName was not preserved.' }
    if(($quotedRows[0].EAName -replace "`r`n", "`n") -ne "Ammar`nTradingGoldEA") { throw 'Embedded line break was not preserved.' }

    Copy-Item -LiteralPath $fixturePath -Destination $sourceCsv -Force
    $preMismatchHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    @([pscustomobject]@{ Enabled='true'; ExpectedMT4Login='999'; SourceCsv=$sourceCsv; OneDriveRoot=$oneDrive }) |
        Export-Csv -LiteralPath $testConfigPath -NoTypeInformation -Encoding utf8
    $mismatch = @(Invoke-MoneyMachineCsvSync -ConfigPath $testConfigPath -StableCheckSeconds 0 -MaxRetries 1 -RuntimeRoot $runtimeRoot)
    if($mismatch[0].Status -ne 'Error') { throw 'Account-login mismatch must return Error.' }
    if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $preMismatchHash) { throw 'A mismatch overwrote a valid destination.' }

    @([pscustomobject]@{ Enabled='true'; ExpectedMT4Login='892522910'; SourceCsv=$sourceCsv; OneDriveRoot=$oneDrive }) |
        Export-Csv -LiteralPath $testConfigPath -NoTypeInformation -Encoding utf8
    $header = Get-Content -LiteralPath $sourceCsv -TotalCount 1
    Set-Content -LiteralPath $sourceCsv -Value $header -Encoding utf8
    $headerOnly = @(Invoke-MoneyMachineCsvSync -ConfigPath $testConfigPath -StableCheckSeconds 0 -MaxRetries 1 -RuntimeRoot $runtimeRoot)
    if($headerOnly[0].Status -ne 'Success') { throw 'A valid schema-v3 header-only CSV must publish successfully.' }
    if(@(Import-Csv -LiteralPath $destination).Count -ne 0) { throw 'Header-only publication must contain zero data rows.' }

    Set-Content -LiteralPath $destination -Value 'known-good-destination' -Encoding utf8
    Set-Content -LiteralPath $sourceCsv -Value @($header, 'bad,row') -Encoding utf8
    $malformed = @(Invoke-MoneyMachineCsvSync -ConfigPath $testConfigPath -StableCheckSeconds 0 -MaxRetries 1 -RuntimeRoot $runtimeRoot)
    if($malformed[0].Status -ne 'Error') { throw 'Malformed CSV must return Error.' }
    if((Get-Content -LiteralPath $destination -Raw) -ne "known-good-destination`r`n") { throw 'Malformed CSV must preserve the previous destination.' }

    $missingConfig = Join-Path $tempRoot 'missing.csv'
    @([pscustomobject]@{ Enabled='true'; ExpectedMT4Login='892522910'; SourceCsv=(Join-Path $tempRoot 'does-not-exist.csv'); OneDriveRoot=$oneDrive }) |
        Export-Csv -LiteralPath $missingConfig -NoTypeInformation -Encoding utf8
    $missing = @(Invoke-MoneyMachineCsvSync -ConfigPath $missingConfig -StableCheckSeconds 0 -MaxRetries 1 -RuntimeRoot $runtimeRoot)
    if($missing[0].Status -ne 'Error') { throw 'An enabled missing source must return Error.' }

    $missingProcess = Start-Process -FilePath $windowsPowerShell -ArgumentList @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
        '-File',('"{0}"' -f $ScriptPath),
        '-ConfigPath',('"{0}"' -f $missingConfig),
        '-StableCheckSeconds','0','-MaxRetries','1','-RuntimeRoot',('"{0}"' -f $runtimeRoot)
    ) -Wait -PassThru
    if($missingProcess.ExitCode -eq 0) { throw 'An enabled missing source must return a nonzero process exit code.' }

    $receiverScript = Join-Path (Split-Path -Parent $ScriptPath) 'Test-MoneyMachineSyncStatus.ps1'
    $receiverRoot = Join-Path $tempRoot 'receiver'
    $receiverAccountDir = Join-Path $receiverRoot 'MoneyMachine\Account_892522910'
    New-Item -ItemType Directory -Path $receiverAccountDir -Force | Out-Null
    $heartbeatPath = Join-Path $receiverAccountDir 'SyncStatus.json'
    [ordered]@{ AccountNumber='892522910'; Status='Success'; PublishedUtc=[DateTime]::UtcNow.ToString('o'); CloudDeliveryVerified=$false } |
        ConvertTo-Json | Set-Content -LiteralPath $heartbeatPath -Encoding utf8
    $receiverFresh = Start-Process -FilePath $windowsPowerShell -ArgumentList @('-NoProfile','-NonInteractive','-File',('"{0}"' -f $receiverScript),'-OneDriveRoot',('"{0}"' -f $receiverRoot),'-ExpectedAccount','892522910') -Wait -PassThru
    if($receiverFresh.ExitCode -ne 0) { throw 'A fresh receiver-side heartbeat must return exit code 0.' }
    [ordered]@{ AccountNumber='892522910'; Status='Success'; PublishedUtc=[DateTime]::UtcNow.AddHours(-27).ToString('o'); CloudDeliveryVerified=$false } |
        ConvertTo-Json | Set-Content -LiteralPath $heartbeatPath -Encoding utf8
    $receiverStale = Start-Process -FilePath $windowsPowerShell -ArgumentList @('-NoProfile','-NonInteractive','-File',('"{0}"' -f $receiverScript),'-OneDriveRoot',('"{0}"' -f $receiverRoot),'-ExpectedAccount','892522910') -Wait -PassThru
    if($receiverStale.ExitCode -eq 0) { throw 'A stale receiver-side heartbeat must return a nonzero exit code.' }

    $installerPath = Join-Path (Split-Path -Parent $ScriptPath) 'Install-BasketsSyncTask.ps1'
    . $installerPath -AsLibrary -ConfigPath $testConfigPath
    Assert-BasketsSyncTaskPrerequisites -PowerShellPath $windowsPowerShell
    $taskDefinition = Get-BasketsSyncTaskDefinition -ResolvedConfig (Resolve-Path -LiteralPath $testConfigPath).Path -SyncScript $ScriptPath -PowerShellPath $windowsPowerShell -WorkingDirectory (Split-Path -Parent $ScriptPath) -DailyTime ([datetime]::Today.AddHours(23).AddMinutes(59)) -TaskName 'MoneyMachine-Test' -PrincipalUser ((& whoami).Trim())
    if(-not [IO.Path]::IsPathRooted($taskDefinition.DailyAction.Execute) -or -not [IO.Path]::IsPathRooted($taskDefinition.DailyAction.WorkingDirectory)) { throw 'Task action executable and working directory must be absolute.' }
    if($taskDefinition.DailyAction.Arguments -notmatch [regex]::Escape($ScriptPath) -or $taskDefinition.DailyAction.Arguments -notmatch [regex]::Escape((Resolve-Path -LiteralPath $testConfigPath).Path)) { throw 'Task action must contain absolute script and config paths.' }
    if([string]$taskDefinition.Settings.MultipleInstances -ne 'IgnoreNew' -or $taskDefinition.Settings.RestartCount -ne 3) { throw 'Task settings must use IgnoreNew and three retries.' }

    Write-Host 'MoneyMachine CSV sync tests passed.'
}
finally {
    if(Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
