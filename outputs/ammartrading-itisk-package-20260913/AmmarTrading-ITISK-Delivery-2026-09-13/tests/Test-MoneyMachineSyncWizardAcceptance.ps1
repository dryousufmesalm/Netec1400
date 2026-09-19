[CmdletBinding()]
param(
    [string]$AutomationRoot = (Join-Path $PSScriptRoot '..\automation\MoneyMachineCsvSync'),
    [string]$PrototypeRoot = (Join-Path $PSScriptRoot '..\prototypes\money-machine-sync-wizard'),
    [string]$BrowserPath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    [string]$EvidenceRoot = 'C:\CodexWorker\MoneyMachine-Wizard-Evidence'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ("MoneyMachineWizardAcceptance_" + [guid]::NewGuid().ToString('N'))
$hostProcess = $null
$fakeTerminalProcess = $null
$oneDriveAccountsKey = 'HKCU:\Software\Microsoft\OneDrive\Accounts'
$oneDriveAccountsKeyExisted = Test-Path -LiteralPath $oneDriveAccountsKey -PathType Container
$testRegistrationKey = $null
$previousOneDrive = $env:OneDrive

try {
    foreach($required in @(
        (Join-Path $AutomationRoot 'Start-MoneyMachineSyncWizard.ps1'),
        (Join-Path $AutomationRoot 'MoneyMachineSyncSetup.psm1'),
        (Join-Path $AutomationRoot 'WizardApp\index.html'),
        (Join-Path $PrototypeRoot 'scripts\accept-windows-wizard.mjs'),
        $BrowserPath
    )) {
        if(-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Acceptance dependency is missing: $required" }
    }

    $oneDriveRoot = Join-Path $stagingRoot 'OneDrive'
    $terminalRoot = Join-Path $stagingRoot 'MetaQuotes\Terminal'
    $sourceDir = Join-Path $terminalRoot 'ACCEPTANCE\MQL4\Files'
    $fakeTerminalRoot = Join-Path $stagingRoot 'FakeMt4'
    $runtimeRoot = Join-Path $stagingRoot 'runtime'
    $configPath = Join-Path $stagingRoot 'config\accounts.csv'
    New-Item -ItemType Directory -Path $oneDriveRoot,$sourceDir,$fakeTerminalRoot,$EvidenceRoot -Force | Out-Null
    $fakeTerminalExe = Join-Path $fakeTerminalRoot 'terminal.exe'
    Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\cmd.exe') -Destination $fakeTerminalExe
    Set-Content -LiteralPath (Join-Path $terminalRoot 'ACCEPTANCE\origin.txt') -Value $fakeTerminalRoot -Encoding utf8
    $fakeTerminalProcess = Start-Process -FilePath $fakeTerminalExe -ArgumentList '/c','ping 127.0.0.1 -n 120 >nul' -PassThru -WindowStyle Hidden
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\AGOLD___Baskets_v3.csv') -Destination (Join-Path $sourceDir 'AGOLD___Baskets.csv')

    if(-not $oneDriveAccountsKeyExisted) { New-Item -Path $oneDriveAccountsKey -Force | Out-Null }
    $testRegistrationKey = Join-Path $oneDriveAccountsKey ("AmmarTradingAcceptance_" + [guid]::NewGuid().ToString('N'))
    New-Item -Path $testRegistrationKey -Force | Out-Null
    New-ItemProperty -LiteralPath $testRegistrationKey -Name 'UserFolder' -Value $oneDriveRoot -PropertyType String -Force | Out-Null
    $env:OneDrive = $oneDriveRoot

    $taskNames = @('MoneyMachine-Baskets-To-OneDrive-Daily','MoneyMachine-Baskets-To-OneDrive-StartupCatchup')
    $tasksBefore = @($taskNames | ForEach-Object { Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue | Select-Object -ExpandProperty TaskName })

    $portProbe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    $portProbe.Start(); $port = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port; $portProbe.Stop()
    $baseUrl = "http://127.0.0.1:$port/"
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $hostProcess = Start-Process -FilePath $powershell -ArgumentList @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $AutomationRoot 'Start-MoneyMachineSyncWizard.ps1')),
        '-Port',$port,'-NoBrowser','-SkipTaskRegistration','-ConfigPath',('"{0}"' -f $configPath),'-RuntimeRoot',('"{0}"' -f $runtimeRoot),
        '-WizardAppRoot',('"{0}"' -f (Join-Path $AutomationRoot 'WizardApp')),'-OneDriveCandidate',('"{0}"' -f $oneDriveRoot),'-TerminalDataRoot',('"{0}"' -f $terminalRoot)
    ) -PassThru -WindowStyle Hidden

    $env:QA_BROWSER = $BrowserPath
    $env:QA_URL = $baseUrl
    $env:QA_OUTPUT = $EvidenceRoot
    & node (Join-Path $PrototypeRoot 'scripts\accept-windows-wizard.mjs')
    if($LASTEXITCODE -ne 0) { throw "Browser acceptance exited $LASTEXITCODE." }

    $destination = Join-Path $oneDriveRoot 'AmmarTrading\Account_892522910\Baskets.csv'
    $heartbeat = Join-Path $oneDriveRoot 'AmmarTrading\Account_892522910\SyncStatus.json'
    if(-not (Test-Path -LiteralPath $destination -PathType Leaf)) { throw 'Acceptance destination CSV is missing.' }
    if(-not (Test-Path -LiteralPath $heartbeat -PathType Leaf)) { throw 'Acceptance heartbeat is missing.' }
    $rows = @(Import-Csv -LiteralPath $configPath)
    if($rows.Count -ne 1 -or $rows[0].VpsName -cne 'VPS Acceptance 01') { throw 'Acceptance config does not contain the browser-created VPS.' }

    $tasksAfter = @($taskNames | ForEach-Object { Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue | Select-Object -ExpandProperty TaskName })
    if(($tasksBefore -join '|') -cne ($tasksAfter -join '|')) { throw 'Staging acceptance changed production scheduled tasks.' }
    Write-Host 'MoneyMachine real Windows wizard acceptance passed.'
}
finally {
    Remove-Item Env:QA_BROWSER,Env:QA_URL,Env:QA_OUTPUT -ErrorAction SilentlyContinue
    if($null -eq $previousOneDrive) { Remove-Item Env:OneDrive -ErrorAction SilentlyContinue } else { $env:OneDrive = $previousOneDrive }
    if($null -ne $hostProcess -and -not $hostProcess.HasExited) { Stop-Process -Id $hostProcess.Id -Force -ErrorAction SilentlyContinue }
    if($null -ne $fakeTerminalProcess -and -not $fakeTerminalProcess.HasExited) { Stop-Process -Id $fakeTerminalProcess.Id -Force -ErrorAction SilentlyContinue }
    if(-not [string]::IsNullOrWhiteSpace($testRegistrationKey) -and (Test-Path -LiteralPath $testRegistrationKey)) {
        Remove-Item -LiteralPath $testRegistrationKey -Recurse -Force
    }
    if(-not $oneDriveAccountsKeyExisted -and (Test-Path -LiteralPath $oneDriveAccountsKey) -and @(Get-ChildItem -LiteralPath $oneDriveAccountsKey).Count -eq 0) {
        Remove-Item -LiteralPath $oneDriveAccountsKey -Force
    }
    if(Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
}
