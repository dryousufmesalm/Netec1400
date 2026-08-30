[CmdletBinding()]
param(
    [string]$SetupModulePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if([string]::IsNullOrWhiteSpace($SetupModulePath)) {
    $SetupModulePath = Join-Path $PSScriptRoot '..\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("AmmarTradingCloudFilesTest_" + [guid]::NewGuid().ToString('N'))
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
    $unregisteredRoot = Join-Path $testRoot 'UnregisteredOneDrive'
    $containedDirectory = Join-Path $trustedRoot 'AmmarTrading\Account_123456'
    New-Item -ItemType Directory -Path $containedDirectory,$unregisteredRoot -Force | Out-Null
    $env:OneDrive = $trustedRoot
    $env:OneDriveCommercial = ''
    $env:OneDriveConsumer = ''
    Remove-Module -Name MoneyMachineSyncSetup -Force -ErrorAction SilentlyContinue
    Import-Module -Name $SetupModulePath -Force -ErrorAction Stop

    $setupModule = Get-Module -Name MoneyMachineSyncSetup
    if((Get-Command Resolve-AmmarTradingOneDriveRoot).Module.Path -cne $setupModule.Path) { throw 'The Cloud Files test did not bind the requested setup module.' }
    & $setupModule {
        $script:AmmarTradingCloudFilesTestTags = @{}
        function script:Get-Item {
            param([Parameter(Mandatory)][string]$LiteralPath,[switch]$Force)
            [pscustomobject]@{ Attributes=([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint) }
        }
        $script:AmmarTradingFileAttributesResolver = {
            param([Parameter(Mandatory)][string]$Path)
            if($script:AmmarTradingCloudFilesTestTags.ContainsKey([IO.Path]::GetFullPath($Path))) {
                return [IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint
            }
            return [IO.FileAttributes]::Directory
        }
        $script:AmmarTradingReparseTagResolver = {
            param([Parameter(Mandatory)][string]$Path)
            return [uint32]$script:AmmarTradingCloudFilesTestTags[[IO.Path]::GetFullPath($Path)]
        }
    }
    $setCloudFilesTag = {
        param([string]$Path,[uint32]$Tag)
        & $setupModule {
            param($Path,$Tag)
            $script:AmmarTradingCloudFilesTestTags[[IO.Path]::GetFullPath($Path)] = $Tag
        } $Path $Tag
    }

    foreach($tagCase in @(
        @{ Name='base Cloud Files'; Tag=[Convert]::ToUInt32('9000001A',16) },
        @{ Name='observed Cloud Files 7'; Tag=[Convert]::ToUInt32('9000701A',16) },
        @{ Name='upper Cloud Files F'; Tag=[Convert]::ToUInt32('9000F01A',16) }
    )) {
        & $setCloudFilesTag $trustedRoot $tagCase.Tag
        $resolved = Resolve-AmmarTradingOneDriveRoot -Path $trustedRoot -RequireWritable
        Assert-True -Condition ($resolved -ceq (Resolve-Path -LiteralPath $trustedRoot).Path) -Message "The $($tagCase.Name) tag must be accepted at the exact signed-in root."
    }

    & $setCloudFilesTag $trustedRoot ([Convert]::ToUInt32('9000701A',16))
    & $setCloudFilesTag $containedDirectory ([Convert]::ToUInt32('9000701A',16))
    $containedPath = Assert-AmmarTradingTrustedDestinationPath -OneDriveRoot $trustedRoot -Path (Join-Path $containedDirectory 'Baskets.csv') -Description 'Contained Cloud Files destination'
    Assert-True -Condition ($containedPath -ceq [IO.Path]::GetFullPath((Join-Path $containedDirectory 'Baskets.csv'))) -Message 'A contained Cloud Files descendant must be accepted.'

    & $setCloudFilesTag $unregisteredRoot ([Convert]::ToUInt32('9000701A',16))
    Assert-ThrowsLike -Expected 'remain below' -Action {
        Assert-AmmarTradingTrustedDestinationPath -OneDriveRoot $trustedRoot -Path (Join-Path $unregisteredRoot 'Baskets.csv') -Description 'Escaped Cloud Files destination' | Out-Null
    }
    Assert-ThrowsLike -Expected 'signed-in OneDrive root' -Action {
        Resolve-AmmarTradingOneDriveRoot -Path $unregisteredRoot -RequireWritable | Out-Null
    }

    foreach($rejectedTag in @(
        @{ Name='junction'; Tag=[Convert]::ToUInt32('A0000003',16) },
        @{ Name='symbolic link'; Tag=[Convert]::ToUInt32('A000000C',16) },
        @{ Name='mount point'; Tag=[Convert]::ToUInt32('A0000003',16) },
        @{ Name='unknown'; Tag=[Convert]::ToUInt32('A000BEEF',16) }
    )) {
        & $setCloudFilesTag $trustedRoot ([Convert]::ToUInt32('9000701A',16))
        & $setCloudFilesTag $containedDirectory $rejectedTag.Tag
        Assert-ThrowsLike -Expected 'unsupported reparse point' -Action {
            Assert-AmmarTradingTrustedDestinationPath -OneDriveRoot $trustedRoot -Path (Join-Path $containedDirectory 'Baskets.csv') -Description "Rejected $($rejectedTag.Name) descendant" | Out-Null
        }
    }

    Write-Host 'AmmarTrading Cloud Files trust-boundary tests passed.'
}
finally {
    $env:OneDrive = $previousOneDrive
    $env:OneDriveCommercial = $previousCommercial
    $env:OneDriveConsumer = $previousConsumer
    if(Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
