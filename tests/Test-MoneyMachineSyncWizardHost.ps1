[CmdletBinding()]
param([string]$ScriptPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $ScriptPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\automation\MoneyMachineCsvSync\Start-MoneyMachineSyncWizard.ps1'
}

function Assert-HostThrowsLike {
    param([scriptblock]$Action,[string]$Expected)
    $threw = $false
    try { & $Action } catch {
        $threw = $true
        if($_.Exception.Message -notmatch [regex]::Escape($Expected)) { throw "Expected '$Expected', got '$($_.Exception.Message)'." }
    }
    if(-not $threw) { throw "Expected an error containing '$Expected'." }
}

function Remove-VerifiedSyntheticOneDriveAccountKey {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $cleanupFailure = $null
    try {
        if(Test-Path -LiteralPath $LiteralPath) { Remove-Item -LiteralPath $LiteralPath -Recurse -Force -ErrorAction Stop }
    } catch { $cleanupFailure = $_ }
    $stillExists = $true
    try { $stillExists = Test-Path -LiteralPath $LiteralPath } catch { if($null -eq $cleanupFailure) { $cleanupFailure = $_ } }
    if($null -ne $cleanupFailure -or $stillExists) { throw "Synthetic OneDrive account registry cleanup failed for '$LiteralPath'." }
}

. $ScriptPath -AsLibrary

$prefix = Get-MoneyMachineWizardPrefix -Port 8765
if($prefix -cne 'http://127.0.0.1:8765/') { throw 'Wizard prefix must bind only to IPv4 loopback.' }
Assert-HostThrowsLike -Expected 'port' -Action { Get-MoneyMachineWizardPrefix -Port 80 | Out-Null }

if(-not (Test-MoneyMachineWizardRoute -Method 'GET' -Path '/api/discovery')) { throw 'Discovery GET must be allowed.' }
if(-not (Test-MoneyMachineWizardRoute -Method 'GET' -Path '/api/accounts')) { throw 'Accounts GET must be allowed.' }
if(-not (Test-MoneyMachineWizardRoute -Method 'POST' -Path '/api/setup')) { throw 'Setup POST must be allowed.' }
if(Test-MoneyMachineWizardRoute -Method 'GET' -Path '/api/setup') { throw 'Setup GET must be rejected.' }
if(Test-MoneyMachineWizardRoute -Method 'POST' -Path '/api/discovery') { throw 'Discovery POST must be rejected.' }

$token = 'test-session-token'
Test-MoneyMachineWizardRequestSecurity -HostHeader '127.0.0.1:8765' -Origin 'http://127.0.0.1:8765' -ExpectedAuthority '127.0.0.1:8765' -CookieHeader "MMWizardSession=$token" -SessionToken $token
Test-MoneyMachineWizardRequestSecurity -HostHeader '127.0.0.1:8765' -Origin '' -ExpectedAuthority '127.0.0.1:8765' -CookieHeader "other=1; MMWizardSession=$token; x=2" -SessionToken $token
Assert-HostThrowsLike -Expected 'Host' -Action { Test-MoneyMachineWizardRequestSecurity -HostHeader 'evil.test' -Origin '' -ExpectedAuthority '127.0.0.1:8765' -CookieHeader "MMWizardSession=$token" -SessionToken $token }
Assert-HostThrowsLike -Expected 'Origin' -Action { Test-MoneyMachineWizardRequestSecurity -HostHeader '127.0.0.1:8765' -Origin 'https://evil.test' -ExpectedAuthority '127.0.0.1:8765' -CookieHeader "MMWizardSession=$token" -SessionToken $token }
Assert-HostThrowsLike -Expected 'session' -Action { Test-MoneyMachineWizardRequestSecurity -HostHeader '127.0.0.1:8765' -Origin '' -ExpectedAuthority '127.0.0.1:8765' -CookieHeader 'MMWizardSession=wrong' -SessionToken $token }

Assert-MoneyMachineWizardBodySize -ContentLength 65536
Assert-HostThrowsLike -Expected '64 KiB' -Action { Assert-MoneyMachineWizardBodySize -ContentLength 65537 }

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("MoneyMachineWizardHostTest_" + [guid]::NewGuid().ToString('N'))
$hostProcess = $null
$fakeTerminalProcess = $null
$testOneDriveAccountKey = 'HKCU:\Software\Microsoft\OneDrive\Accounts\AmmarTradingWizardHostTest_' + [guid]::NewGuid().ToString('N')
try {
    $appRoot = Join-Path $tempRoot 'WizardApp'
    $oneDriveRoot = Join-Path $tempRoot 'OneDrive'
    $terminalRoot = Join-Path $tempRoot 'MetaQuotes\Terminal'
    $sourceDir = Join-Path $terminalRoot 'HOSTTEST\MQL4\Files'
    $fakeTerminalRoot = Join-Path $tempRoot 'FakeMt4'
    $runtimeRoot = Join-Path $tempRoot 'runtime'
    $configPath = Join-Path $tempRoot 'config\accounts.csv'
    New-Item -ItemType Directory -Path $appRoot,$oneDriveRoot,$sourceDir,$fakeTerminalRoot,(Split-Path -Parent $configPath) -Force | Out-Null
    $fakeTerminalExe = Join-Path $fakeTerminalRoot 'terminal.exe'
    Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\cmd.exe') -Destination $fakeTerminalExe
    Set-Content -LiteralPath (Join-Path $terminalRoot 'HOSTTEST\origin.txt') -Value $fakeTerminalRoot -Encoding utf8
    $fakeTerminalProcess = Start-Process -FilePath $fakeTerminalExe -ArgumentList '/c','ping 127.0.0.1 -n 120 >nul' -PassThru -WindowStyle Hidden
    New-Item -Path $testOneDriveAccountKey -Force | Out-Null
    New-ItemProperty -LiteralPath $testOneDriveAccountKey -Name 'UserFolder' -Value $oneDriveRoot -PropertyType String -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $appRoot 'index.html') -Value '<!doctype html><html><body>Wizard host test</body></html>' -Encoding utf8
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'fixtures\AGOLD___Baskets_v3.csv') -Destination (Join-Path $sourceDir 'AGOLD___Baskets.csv')

    $testVpsId = '0123456789abcdef0123456789abcdef'
    $canonicalAccountDir = Join-Path $oneDriveRoot (Join-Path 'amartrading' (Join-Path ("VPS_{0}" -f $testVpsId) 'Account_892522910'))
    New-Item -ItemType Directory -Path $canonicalAccountDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceDir 'AGOLD___Baskets.csv') -Destination (Join-Path $canonicalAccountDir 'Baskets.csv')
    @([pscustomobject]@{ Enabled='true'; VpsName='Canonical Account'; VpsId=$testVpsId; ExpectedMT4Login='892522910'; SourceCsv=(Join-Path $sourceDir 'AGOLD___Baskets.csv'); OneDriveRoot=$oneDriveRoot }) |
        Export-Csv -LiteralPath $configPath -NoTypeInformation -Encoding utf8
    $canonicalAccount = @(Get-MoneyMachineWizardAccounts -ConfigPath $configPath)
    if($canonicalAccount.Count -ne 1 -or $canonicalAccount[0].files -ne 1 -or -not $canonicalAccount[0].localPublished) { throw 'Accounts API lookup must recognize a canonical AmmarTrading publication.' }

    $portProbe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    $portProbe.Start()
    $port = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
    $portProbe.Stop()
    $baseUrl = "http://127.0.0.1:$port/"
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $hostProcess = Start-Process -FilePath $powershell -ArgumentList @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $ScriptPath),
        '-Port',$port,'-NoBrowser','-SkipTaskRegistration',
        '-ConfigPath',('"{0}"' -f $configPath),'-RuntimeRoot',('"{0}"' -f $runtimeRoot),'-WizardAppRoot',('"{0}"' -f $appRoot),
        '-OneDriveCandidate',('"{0}"' -f $oneDriveRoot),'-TerminalDataRoot',('"{0}"' -f $terminalRoot)
    ) -PassThru -WindowStyle Hidden

    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    $rootResponse = $null
    while($null -eq $rootResponse -and [DateTime]::UtcNow -lt $deadline) {
        try { $rootResponse = Invoke-WebRequest -UseBasicParsing -Uri $baseUrl -SessionVariable wizardSession -TimeoutSec 2 } catch { Start-Sleep -Milliseconds 200 }
    }
    if($null -eq $rootResponse) { throw 'Wizard host did not start on the loopback endpoint.' }
    if($rootResponse.StatusCode -ne 200 -or $rootResponse.Content -notmatch 'Wizard host test') { throw 'Wizard host must serve its app index.' }
    if($rootResponse.Headers['Content-Security-Policy'] -notmatch "default-src 'self'") { throw 'Wizard app responses must set a restrictive Content-Security-Policy.' }

    $unauthorizedStatus = 0
    try { Invoke-WebRequest -UseBasicParsing -Uri ($baseUrl + 'api/discovery') -TimeoutSec 2 | Out-Null } catch { $unauthorizedStatus = [int]$_.Exception.Response.StatusCode }
    if($unauthorizedStatus -ne 403) { throw 'API requests without the session cookie must return 403.' }

    $discovery = Invoke-RestMethod -Uri ($baseUrl + 'api/discovery') -WebSession $wizardSession -TimeoutSec 5
    if(-not $discovery.ok -or @($discovery.oneDriveRoots).Count -ne 1 -or @($discovery.sources).Count -ne 1) { throw 'Authenticated discovery must return the injected OneDrive and MT4 source.' }

    $browserDiscoveryCommand = @{ version=1; id='host-test-discover'; command='discoverMt4Accounts'; payload=@{} } | ConvertTo-Json -Compress
    $browserDiscovery = Invoke-RestMethod -Method Post -Uri ($baseUrl + 'api/command') -WebSession $wizardSession -Headers @{ Origin=$baseUrl.TrimEnd('/') } -ContentType 'application/json' -Body $browserDiscoveryCommand -TimeoutSec 5
    if(-not $browserDiscovery.ok -or @($browserDiscovery.data.accounts).Count -ne 1 -or $browserDiscovery.data.accounts[0].AccountNumber -cne '892522910') { throw 'Browser MT4 discovery must return the injected terminal account.' }

    $payload = @{
        vpsName = 'Host Test VPS'
        expectedMT4Login = '892522910'
        sourceCsv = (Join-Path $sourceDir 'AGOLD___Baskets.csv')
        oneDriveRoot = $oneDriveRoot
    } | ConvertTo-Json
    $setup = Invoke-RestMethod -Method Post -Uri ($baseUrl + 'api/setup') -WebSession $wizardSession -ContentType 'application/json' -Body $payload -TimeoutSec 15
    if(-not $setup.ok -or $setup.status -cne 'Success' -or -not (Test-Path -LiteralPath $setup.destination -PathType Leaf)) { throw 'Authenticated setup must publish the staged CSV and return Success.' }

    $accounts = Invoke-RestMethod -Uri ($baseUrl + 'api/accounts') -WebSession $wizardSession -TimeoutSec 5
    if(@($accounts.accounts).Count -ne 1 -or $accounts.accounts[0].vpsName -cne 'Host Test VPS') { throw 'Accounts API must return the newly configured VPS.' }
    if($accounts.accounts[0].files -ne 1 -or -not $accounts.accounts[0].localPublished -or [string]::IsNullOrWhiteSpace([string]$accounts.accounts[0].lastWriteUtc)) { throw 'Accounts API must report the real locally published CSV and timestamp.' }

    $badOriginStatus = 0
    try { Invoke-WebRequest -UseBasicParsing -Uri ($baseUrl + 'api/accounts') -WebSession $wizardSession -Headers @{ Origin='https://evil.test' } -TimeoutSec 2 | Out-Null } catch { $badOriginStatus = [int]$_.Exception.Response.StatusCode }
    if($badOriginStatus -ne 403) { throw 'An authenticated request with a foreign Origin must return 403.' }

    Write-Host 'MoneyMachine wizard host security and integration tests passed.'
}
finally {
    if($null -ne $hostProcess -and -not $hostProcess.HasExited) { Stop-Process -Id $hostProcess.Id -Force -ErrorAction SilentlyContinue }
    if($null -ne $fakeTerminalProcess -and -not $fakeTerminalProcess.HasExited) { Stop-Process -Id $fakeTerminalProcess.Id -Force -ErrorAction SilentlyContinue }
    try { Remove-VerifiedSyntheticOneDriveAccountKey -LiteralPath $testOneDriveAccountKey }
    finally {
        if(Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}
