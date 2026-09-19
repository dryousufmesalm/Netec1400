param(
    [string]$PackageRoot = 'D:\CodexWorker\ammartrading-vpsid-remotesigned-test-20260915\package\AmarTradingSync',
    [switch]$SkipSignature
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$jobRoot = 'D:\CodexWorker\ammartrading-vpsid-remotesigned-test-20260915\e2e'
$fixturePath = 'D:\CodexWorker\ammartrading-vpsid-remotesigned-test-20260915\AGOLD___Baskets_v3.csv'
$rootThumb = '38B79244D76FD3CA939BFC7A8DCE298B3EB46954'
$publisherThumb = '78CD4F582A134F1AFAC7C1E63EC5EFA7567A9F3B'
$hadRoot = Test-Path -LiteralPath "Cert:\LocalMachine\Root\$rootThumb"
$hadPublisher = Test-Path -LiteralPath "Cert:\LocalMachine\TrustedPublisher\$publisherThumb"
$originalAppData = $env:APPDATA
$hostProcess = $null
$fakeTerminalProcess = $null
$testOneDriveAccountKey = 'HKCU:\Software\Microsoft\OneDrive\Accounts\AmmarTradingBrowserE2E_' + [guid]::NewGuid().ToString('N')

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if(-not $Condition) { throw $Message }
}

try {
    Remove-Item -LiteralPath $jobRoot -Recurse -Force -ErrorAction SilentlyContinue
    $appData = Join-Path $jobRoot 'AppData'
    $oneDrive = Join-Path $jobRoot 'OneDrive'
    $runtime = Join-Path $jobRoot 'Runtime'
    $config = Join-Path $runtime 'accounts.csv'
    $source = Join-Path $appData 'MetaQuotes\Terminal\E2E01\MQL4\Files\AGOLD___Baskets.csv'
    $terminalRoot = Join-Path $appData 'MetaQuotes\Terminal'
    $fakeTerminalRoot = Join-Path $jobRoot 'FakeMt4'
    New-Item -ItemType Directory -Path (Split-Path -Parent $source),$oneDrive,$runtime,$fakeTerminalRoot -Force | Out-Null
    $rows = @(Import-Csv -LiteralPath $fixturePath)
    foreach($row in $rows) { $row.AccountNumber = '892525902'; $row.BrokerName = 'E2E Broker' }
    $rows | Export-Csv -LiteralPath $source -NoTypeInformation -Encoding utf8
    $fakeTerminalExe = Join-Path $fakeTerminalRoot 'terminal.exe'
    Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\cmd.exe') -Destination $fakeTerminalExe
    Set-Content -LiteralPath (Join-Path $terminalRoot 'E2E01\origin.txt') -Value $fakeTerminalRoot -Encoding utf8
    $fakeTerminalProcess = Start-Process -FilePath $fakeTerminalExe -ArgumentList '/c','ping 127.0.0.1 -n 120 >nul' -PassThru -WindowStyle Hidden
    New-Item -Path $testOneDriveAccountKey -Force | Out-Null
    New-ItemProperty -LiteralPath $testOneDriveAccountKey -Name 'UserFolder' -Value $oneDrive -PropertyType String -Force | Out-Null

    if(-not $SkipSignature) {
        if(-not $hadRoot) { Import-Certificate -FilePath (Join-Path $packageRoot 'AmarTrading-Test-Root.cer') -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null }
        if(-not $hadPublisher) { Import-Certificate -FilePath (Join-Path $packageRoot 'AmarTrading-Test-Publisher.cer') -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher' | Out-Null }
        $moduleSignature = Get-AuthenticodeSignature -FilePath (Join-Path $packageRoot 'MoneyMachineSyncSetup.psm1')
        Assert-True -Condition ($moduleSignature.Status -eq 'Valid') -Message "Corrected module signature is $($moduleSignature.Status)."
    }

    $env:APPDATA = $appData
    $hostScript = Join-Path $packageRoot 'Start-MoneyMachineSyncWizard.ps1'
    $hostProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','RemoteSigned','-File',$hostScript,
        '-NoBrowser','-Port','8880','-SkipTaskRegistration',
        '-RuntimeRoot',$runtime,'-ConfigPath',$config,'-TerminalDataRoot',$terminalRoot
    ) -PassThru -WindowStyle Hidden

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $ready = $false
    for($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8880/' -WebSession $session -TimeoutSec 1
            if($response.StatusCode -eq 200) { $ready = $true; break }
        } catch {}
    }
    Assert-True -Condition $ready -Message 'Browser app did not start.'

    $sequence = 0
    function Invoke-BrowserCommand {
        param([string]$Command,[object]$Payload)
        $script:sequence++
        $body = @{ version=1; id=("e2e-$script:sequence"); command=$Command; payload=$Payload } | ConvertTo-Json -Depth 8 -Compress
        $reply = Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8880/api/command' -WebSession $session -Headers @{ Origin='http://127.0.0.1:8880' } -ContentType 'application/json' -Body $body
        $replyMessage = if($reply.PSObject.Properties['message']) { [string]$reply.message } else { '<no message>' }
        Assert-True -Condition ([bool]$reply.ok) -Message "Browser command '$Command' failed: $replyMessage. Reply=$($reply | ConvertTo-Json -Depth 10 -Compress)"
        return $reply.data
    }

    $discovery = Invoke-BrowserCommand -Command 'discoverMt4Accounts' -Payload ([pscustomobject]@{})
    $account = @($discovery.Accounts | Where-Object { $_.AccountNumber -eq '892525902' -and $_.Eligibility -eq 'Ready' })[0]
    Assert-True -Condition ($null -ne $account) -Message 'Browser discovery did not return the ready Schema V3 fixture.'

    $selection = [pscustomobject]@{
        vpsName = 'VPS E2E Test'
        oneDriveRoot = $oneDrive
        accounts = @([pscustomobject]@{ discoveryId=$account.DiscoveryId; expectedMT4Login=$account.AccountNumber; sourceCsv=$account.SourceCsv })
    }
    $validation = Invoke-BrowserCommand -Command 'validateSelection' -Payload $selection
    Assert-True -Condition (@($validation.Stages | Where-Object { $_.Code -eq 'Validated' -and $_.Status -eq 'Success' }).Count -eq 1) -Message 'Browser validation did not succeed.'

    $applied = Invoke-BrowserCommand -Command 'applySetup' -Payload $selection
    Assert-True -Condition ($applied.Status -eq 'Success') -Message 'Browser apply setup did not succeed.'
    $configured = @($applied.Accounts | Where-Object { $_.AccountNumber -eq '892525902' })[0]
    Assert-True -Condition ($null -ne $configured -and [bool]$configured.LocalPublished) -Message 'Apply setup did not publish the selected account locally.'
    Assert-True -Condition (Test-Path -LiteralPath $configured.Destination -PathType Leaf) -Message 'Published CSV is missing.'

    $sync = Invoke-BrowserCommand -Command 'runSyncNow' -Payload ([pscustomobject]@{ accountNumbers=@('892525902') })
    Assert-True -Condition ($sync.Status -eq 'Success') -Message 'Browser run sync now did not succeed.'
    $status = Invoke-BrowserCommand -Command 'getConfiguredAccounts' -Payload ([pscustomobject]@{})
    $statusAccount = @($status.Accounts | Where-Object { $_.AccountNumber -eq '892525902' -and $_.Status -eq 'Success' })[0]
    Assert-True -Condition ($null -ne $statusAccount) -Message 'Browser status did not report a successful local sync.'
    Write-Output "BROWSER_E2E_PASS ACCOUNT=$($account.AccountNumber) DESTINATION=$($configured.Destination)"
}
finally {
    if($null -ne $hostProcess -and -not $hostProcess.HasExited) { Stop-Process -Id $hostProcess.Id -Force }
    if($null -ne $fakeTerminalProcess -and -not $fakeTerminalProcess.HasExited) { Stop-Process -Id $fakeTerminalProcess.Id -Force }
    if(Test-Path -LiteralPath $testOneDriveAccountKey) { Remove-Item -LiteralPath $testOneDriveAccountKey -Recurse -Force -ErrorAction SilentlyContinue }
    $env:APPDATA = $originalAppData
    if(-not $hadPublisher) { Remove-Item -LiteralPath "Cert:\LocalMachine\TrustedPublisher\$publisherThumb" -Force -ErrorAction SilentlyContinue }
    if(-not $hadRoot) { Remove-Item -LiteralPath "Cert:\LocalMachine\Root\$rootThumb" -Force -ErrorAction SilentlyContinue }
}
