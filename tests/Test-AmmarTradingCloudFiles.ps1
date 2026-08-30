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
    $threw = $false
    try { & $Action }
    catch {
        $threw = $true
        if($_.Exception.Message -notmatch [regex]::Escape($Expected)) { throw }
    }
    if(-not $threw) { throw "Expected failure containing '$Expected'." }
}

$nonThrowingActionWasRejected = $false
try {
    Assert-ThrowsLike -Expected 'must fail for a non-throwing action' -Action {}
} catch {
    $nonThrowingActionWasRejected = $true
}
Assert-True -Condition $nonThrowingActionWasRejected -Message 'Assert-ThrowsLike must fail when its action does not throw.'

try {
    $trustedRoot = Join-Path $testRoot 'TrustedOneDrive'
    $secondaryRoot = Join-Path $testRoot 'SecondaryOneDrive'
    $staleRoot = Join-Path $testRoot 'StaleOneDrive'
    $unregisteredRoot = Join-Path $testRoot 'UnregisteredOneDrive'
    $containedDirectory = Join-Path $trustedRoot 'AmmarTrading\Account_123456'
    New-Item -ItemType Directory -Path $containedDirectory,$unregisteredRoot,$secondaryRoot -Force | Out-Null
    $env:OneDrive = $trustedRoot
    $env:OneDriveCommercial = ''
    $env:OneDriveConsumer = ''
    Remove-Module -Name MoneyMachineSyncSetup -Force -ErrorAction SilentlyContinue
    Import-Module -Name $SetupModulePath -Force -ErrorAction Stop

    $setupModule = Get-Module -Name MoneyMachineSyncSetup
    if((Get-Command Resolve-AmmarTradingOneDriveRoot).Module.Path -cne $setupModule.Path) { throw 'The Cloud Files test did not bind the requested setup module.' }
    $nativeInfo = & $setupModule {
        param($Path)
        Get-AmmarTradingFileAttributeTagInfo -Path $Path
    } $testRoot
    Assert-True -Condition ($null -ne $nativeInfo.FileAttributes -and [uint32]$nativeInfo.ReparseTag -eq 0) -Message 'The Windows FileAttributeTagInfo handle query must return one native attribute/tag result for a normal directory.'
    & $setupModule {
        param($RegisteredRoot)
        $script:AmmarTradingCloudFilesTestTags = @{}
        $script:AmmarTradingCloudFilesTestMetadata = @{}
        $script:AmmarTradingCloudFilesTestMetadataCalls = 0
        $script:AmmarTradingCloudFilesTestRegisteredRoots = @($RegisteredRoot)
        $script:AmmarTradingOneDriveRegistrationResolver = { @($script:AmmarTradingCloudFilesTestRegisteredRoots) }
        function script:Get-Item {
            param([Parameter(Mandatory)][string]$LiteralPath,[switch]$Force)
            [pscustomobject]@{ Attributes=([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint) }
        }
        $script:AmmarTradingFileAttributeTagResolver = {
            param([Parameter(Mandatory)][string]$Path)
            $script:AmmarTradingCloudFilesTestMetadataCalls++
            $key = [IO.Path]::GetFullPath($Path)
            if($script:AmmarTradingCloudFilesTestMetadata.ContainsKey($key)) {
                return $script:AmmarTradingCloudFilesTestMetadata[$key]
            }
            if($script:AmmarTradingCloudFilesTestTags.ContainsKey($key)) {
                return [pscustomobject]@{
                    FileAttributes = [IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint
                    ReparseTag = [uint32]$script:AmmarTradingCloudFilesTestTags[$key]
                }
            }
            return [pscustomobject]@{
                FileAttributes = [IO.FileAttributes]::Directory
                ReparseTag = [uint32]0
            }
        }
    } $trustedRoot
    $setCloudFilesTag = {
        param([string]$Path,[uint32]$Tag)
        & $setupModule {
            param($Path,$Tag)
            $key = [IO.Path]::GetFullPath($Path)
            [void]$script:AmmarTradingCloudFilesTestMetadata.Remove($key)
            $script:AmmarTradingCloudFilesTestTags[$key] = $Tag
        } $Path $Tag
    }
    $setFileMetadata = {
        param([string]$Path,[IO.FileAttributes]$Attributes,[uint32]$Tag)
        & $setupModule {
            param($Path,$Attributes,$Tag)
            $script:AmmarTradingCloudFilesTestMetadata[[IO.Path]::GetFullPath($Path)] = [pscustomobject]@{
                FileAttributes = $Attributes
                ReparseTag = $Tag
            }
        } $Path $Attributes $Tag
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
    & $setFileMetadata $containedDirectory ([IO.FileAttributes]::Directory) ([Convert]::ToUInt32('9000701A',16))
    Assert-ThrowsLike -Expected 'inconsistent reparse metadata' -Action {
        Assert-AmmarTradingTrustedDestinationPath -OneDriveRoot $trustedRoot -Path (Join-Path $containedDirectory 'Baskets.csv') -Description 'Inconsistent Cloud Files metadata' | Out-Null
    }
    & $setCloudFilesTag $containedDirectory ([Convert]::ToUInt32('9000701A',16))

    & $setCloudFilesTag $unregisteredRoot ([Convert]::ToUInt32('9000701A',16))
    Assert-ThrowsLike -Expected 'remain below' -Action {
        Assert-AmmarTradingTrustedDestinationPath -OneDriveRoot $trustedRoot -Path (Join-Path $unregisteredRoot 'Baskets.csv') -Description 'Escaped Cloud Files destination' | Out-Null
    }
    Assert-ThrowsLike -Expected 'signed-in OneDrive root' -Action {
        Resolve-AmmarTradingOneDriveRoot -Path $unregisteredRoot -RequireWritable | Out-Null
    }

    # OneDrive registry registration, not a process-controlled environment value, is the trust source.
    & $setupModule {
        param($RegisteredRoot)
        $script:AmmarTradingCloudFilesTestRegisteredRoots = @($RegisteredRoot)
    } $trustedRoot
    $env:OneDrive = $unregisteredRoot
    Assert-ThrowsLike -Expected 'signed-in OneDrive root' -Action {
        Resolve-AmmarTradingOneDriveRoot -Path $unregisteredRoot -RequireWritable | Out-Null
    }
    $env:OneDrive = $trustedRoot

    & $setupModule {
        param($FirstRoot,$SecondRoot)
        $script:AmmarTradingCloudFilesTestRegisteredRoots = @($FirstRoot,$SecondRoot)
    } $trustedRoot $secondaryRoot
    $registeredRoots = @(& $setupModule { @(Get-AmmarTradingWritableOneDriveRoots) })
    Assert-True -Condition ($registeredRoots.Count -eq 2) -Message 'Each current-user OneDrive account registration must be considered.'
    Assert-True -Condition ([bool]($registeredRoots | Where-Object { $_.Path -ieq [IO.Path]::GetFullPath($trustedRoot) -and $_.IsActive })) -Message 'An exact environment hint must mark its registered root active.'
    Assert-True -Condition (-not [bool]($registeredRoots | Where-Object { $_.Path -ieq [IO.Path]::GetFullPath($secondaryRoot) -and $_.IsActive })) -Message 'An unmatched registered root must not be marked active.'
    $secondaryResolved = Resolve-AmmarTradingOneDriveRoot -Path $secondaryRoot -RequireWritable
    Assert-True -Condition ($secondaryResolved -ceq [IO.Path]::GetFullPath($secondaryRoot)) -Message 'A second registered OneDrive account root must resolve.'

    & $setupModule {
        param($StaleRoot)
        $script:AmmarTradingCloudFilesTestRegisteredRoots = @($StaleRoot)
    } $staleRoot
    $env:OneDrive = $staleRoot
    $staleRoots = @(& $setupModule { @(Get-AmmarTradingWritableOneDriveRoots) })
    Assert-True -Condition ($staleRoots.Count -eq 0) -Message 'A stale OneDrive registration must not become an eligible root.'
    Assert-ThrowsLike -Expected 'was not found' -Action {
        Resolve-AmmarTradingOneDriveRoot -Path $staleRoot -RequireWritable | Out-Null
    }
    & $setupModule {
        param($RegisteredRoot)
        $script:AmmarTradingCloudFilesTestRegisteredRoots = @($RegisteredRoot)
    } $trustedRoot
    $env:OneDrive = $trustedRoot

    foreach($driveCase in @(
        @{ Name='removable'; Type=[IO.DriveType]::Removable; Expected='local fixed filesystem' },
        @{ Name='RAM disk'; Type=[IO.DriveType]::Ram; Expected='local fixed filesystem' },
        @{ Name='unknown drive'; Type=[IO.DriveType]::Unknown; Expected='local fixed filesystem' },
        @{ Name='network drive'; Type=[IO.DriveType]::Network; Expected='mapped network drives' }
    )) {
        & $setupModule {
            param($DriveType)
            $script:AmmarTradingCloudFilesTestDriveType = $DriveType
            $script:AmmarTradingDriveTypeResolver = { param($VolumeRoot) return $script:AmmarTradingCloudFilesTestDriveType }
        } $driveCase.Type
        Assert-ThrowsLike -Expected $driveCase.Expected -Action {
            Resolve-AmmarTradingOneDriveRoot -Path $trustedRoot -RequireWritable | Out-Null
        }
    }
    & $setupModule {
        $script:AmmarTradingDriveTypeResolver = { param($VolumeRoot) return [IO.DriveType]::Fixed }
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
