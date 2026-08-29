[CmdletBinding()]
param(
    [string]$SetupModulePath,
    [string]$EntryPoint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if([string]::IsNullOrWhiteSpace($SetupModulePath)) {
    $SetupModulePath = Join-Path $PSScriptRoot '..\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1'
}
if([string]::IsNullOrWhiteSpace($EntryPoint)) {
    $EntryPoint = Join-Path $PSScriptRoot '..\automation\MoneyMachineCsvSync\Invoke-AmmarTradingDesktopOperation.ps1'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("AmmarTradingDesktopSecurityTest_" + [guid]::NewGuid().ToString('N'))
$previousOneDrive = $env:OneDrive
$previousCommercial = $env:OneDriveCommercial
$previousConsumer = $env:OneDriveConsumer

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if(-not $Condition) { throw $Message }
}

function Assert-ThrowsLike {
    param([string]$Expected,[scriptblock]$Action)
    try { & $Action; throw "Expected failure containing '$Expected'." }
    catch { if($_.Exception.Message -notmatch [regex]::Escape($Expected)) { throw } }
}

try {
    $trustedRoot = Join-Path $testRoot 'TrustedOneDrive'
    $arbitraryRoot = Join-Path $testRoot 'ArbitraryLocalDirectory'
    $reparseTarget = Join-Path $testRoot 'ReparseTarget'
    New-Item -ItemType Directory -Path $trustedRoot,$arbitraryRoot,$reparseTarget -Force | Out-Null
    $env:OneDrive = $trustedRoot
    $env:OneDriveCommercial = ''
    $env:OneDriveConsumer = ''
    Import-Module -Name $SetupModulePath -Force -ErrorAction Stop

    $trusted = Resolve-AmmarTradingOneDriveRoot -Path $trustedRoot -RequireWritable
    Assert-True -Condition ($trusted -ceq (Resolve-Path -LiteralPath $trustedRoot).Path) -Message 'The exact writable signed-in OneDrive root must be accepted.'
    Assert-ThrowsLike -Expected 'signed-in OneDrive root' -Action {
        Resolve-AmmarTradingOneDriveRoot -Path $arbitraryRoot -RequireWritable | Out-Null
    }
    Assert-ThrowsLike -Expected 'UNC' -Action {
        Resolve-AmmarTradingOneDriveRoot -Path '\\localhost\AmmarTradingMissing\OneDrive' -RequireWritable | Out-Null
    }
    Assert-ThrowsLike -Expected 'UNC' -Action {
        Resolve-AmmarTradingOneDriveRoot -Path 'FileSystem::\\localhost\AmmarTradingMissing\OneDrive' -RequireWritable | Out-Null
    }

    $setupModule = Get-Module -Name MoneyMachineSyncSetup
    & $setupModule { $script:AmmarTradingDriveTypeResolver = { param([string]$Root) [IO.DriveType]::Network } }
    try {
        Assert-True -Condition (@(Get-AmmarTradingWritableOneDriveRoots).Count -eq 0) -Message 'A mapped-network OneDrive candidate must not be enumerated.'
        Assert-ThrowsLike -Expected 'local filesystem' -Action {
            Resolve-AmmarTradingOneDriveRoot -Path $trustedRoot -RequireWritable | Out-Null
        }
    } finally {
        Import-Module -Name $SetupModulePath -Force -ErrorAction Stop
    }

    $link = Join-Path $testRoot 'ReparseAncestor'
    New-Item -ItemType Junction -Path $link -Target $reparseTarget | Out-Null
    $redirectedCsv = Join-Path $link 'AGOLD___Baskets.csv'
    Set-Content -LiteralPath (Join-Path $reparseTarget 'AGOLD___Baskets.csv') -Value 'header' -Encoding utf8
    Assert-ThrowsLike -Expected 'reparse' -Action {
        Resolve-AmmarTradingLocalPath -Path $redirectedCsv -PathType Leaf -Description 'Redirected CSV' | Out-Null
    }

    $runtimeRoot = Join-Path $testRoot 'runtime'
    $configPath = Join-Path $runtimeRoot 'accounts.csv'
    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    Set-Content -LiteralPath $configPath -Value @(
        'Enabled,VpsName,ExpectedMT4Login,SourceCsv,OneDriveRoot',
        'false,Original,123456,C:\original.csv,C:\original-drive'
    ) -Encoding utf8
    $originalHash = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    Start-AmmarTradingSetupTransaction -RuntimeRoot $runtimeRoot -ConfigPath $configPath
    Set-Content -LiteralPath $configPath -Value 'mutated-after-marker' -Encoding utf8
    $published = Join-Path $trustedRoot 'AmmarTrading\Account_123456\Baskets.csv'
    New-Item -ItemType Directory -Path (Split-Path -Parent $published) -Force | Out-Null
    Set-Content -LiteralPath $published -Value 'published-data-must-remain' -Encoding utf8

    $requestRoot = Join-Path $runtimeRoot 'requests'
    New-Item -ItemType Directory -Path $requestRoot -Force | Out-Null
    $requestPath = Join-Path $requestRoot 'request.recovery.json'
    [IO.File]::WriteAllText($requestPath, '{}', (New-Object Text.UTF8Encoding($false)))
    $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $windowsPowerShell -NoProfile -NonInteractive -File $EntryPoint -Operation SystemStatus -RequestPath $requestPath -RuntimeRoot $runtimeRoot | Out-Null
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message 'A subsequent desktop operation must run recovery before dispatch.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ceq $originalHash) -Message 'Crash recovery must restore the exact pre-mutation configuration.'
    Assert-True -Condition (Test-Path -LiteralPath $published -PathType Leaf) -Message 'Crash recovery must not delete already-published OneDrive data.'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $runtimeRoot 'state\setup-transaction.json'))) -Message 'Crash recovery must consume the transaction marker.'

    @([pscustomobject][ordered]@{
        Enabled='true'
        VpsName='Untrusted stored root'
        ExpectedMT4Login='123456'
        SourceCsv=(Join-Path $testRoot 'missing.csv')
        OneDriveRoot=$arbitraryRoot
    }) | Export-Csv -LiteralPath $configPath -NoTypeInformation -Encoding utf8
    $requestPath = Join-Path $requestRoot 'request.status.json'
    [IO.File]::WriteAllText($requestPath, '{}', (New-Object Text.UTF8Encoding($false)))
    $statusJson = & $windowsPowerShell -NoProfile -NonInteractive -File $EntryPoint -Operation Status -RequestPath $requestPath -RuntimeRoot $runtimeRoot
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message 'Status must safely classify an untrusted stored OneDrive root.'
    $status = $statusJson | ConvertFrom-Json
    Assert-True -Condition ($status.Accounts[0].StatusCode -ceq 'UntrustedOneDriveRoot') -Message 'Status must revalidate stored roots against current OneDrive roots.'
    Assert-True -Condition ([string]::IsNullOrWhiteSpace([string]$status.Accounts[0].Destination)) -Message 'Status must not derive a destination from an untrusted stored root.'

    $requestPath = Join-Path $requestRoot 'request.sync-now.json'
    [IO.File]::WriteAllText($requestPath, '{}', (New-Object Text.UTF8Encoding($false)))
    $syncJson = & $windowsPowerShell -NoProfile -NonInteractive -File $EntryPoint -Operation SyncNow -RequestPath $requestPath -RuntimeRoot $runtimeRoot
    Assert-True -Condition ($LASTEXITCODE -eq 1) -Message 'SyncNow must fail closed for an untrusted stored OneDrive root.'
    $syncResponse = $syncJson | ConvertFrom-Json
    Assert-True -Condition ($syncResponse.Code -ceq 'OperationFailed') -Message 'SyncNow must return only its stable desktop failure code.'
    $lastRun = Get-Content -LiteralPath (Join-Path $runtimeRoot 'state\last-run.json') -Raw | ConvertFrom-Json
    Assert-True -Condition ($lastRun.Accounts.'123456'.FailureCode -ceq 'UntrustedOneDriveRoot') -Message 'SyncNow must revalidate the stored root before source access or publication.'
    $safeSyncDiagnostics = @($syncJson,(Get-Content -LiteralPath (Join-Path $runtimeRoot 'state\last-run.json') -Raw)) -join [Environment]::NewLine
    Assert-True -Condition (-not $safeSyncDiagnostics.Contains($arbitraryRoot)) -Message 'SyncNow response and last-run diagnostics must not expose the untrusted path.'

    Write-Host 'AmmarTrading desktop security boundary tests passed.'
}
finally {
    $env:OneDrive = $previousOneDrive
    $env:OneDriveCommercial = $previousCommercial
    $env:OneDriveConsumer = $previousConsumer
    if(Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
