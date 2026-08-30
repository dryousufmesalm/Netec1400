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
    $identityMutationDirectory = Join-Path $trustedRoot 'IdentityMutationTarget'
    $handleLockDirectory = Join-Path $trustedRoot 'HandleLockTarget'
    New-Item -ItemType Directory -Path $containedDirectory,$identityMutationDirectory,$handleLockDirectory,$unregisteredRoot,$secondaryRoot -Force | Out-Null
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
        $script:AmmarTradingCloudFilesTestRegistrationCalls = 0
        $script:AmmarTradingCloudFilesTestRegisteredRoots = @($RegisteredRoot)
        $script:AmmarTradingOneDriveRegistrationResolver = {
            $script:AmmarTradingCloudFilesTestRegistrationCalls++
            @($script:AmmarTradingCloudFilesTestRegisteredRoots)
        }
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

    # A changed ancestor/final file identity sampled after initial validation
    # must fail before the protected path operation executes.
    & $setupModule {
        param($MutationPath)
        $script:AmmarTradingCloudFilesIdentityMutationPath = [IO.Path]::GetFullPath($MutationPath)
        $script:AmmarTradingCloudFilesIdentityMutationArmed = $false
        $script:AmmarTradingCloudFilesProtectedActionRan = $false
        $script:AmmarTradingHeldPathMetadataResolver = {
            param($Handle,$Path)
            $metadata = Get-AmmarTradingNativeHandleMetadata -Handle $Handle
            if($script:AmmarTradingCloudFilesIdentityMutationArmed -and
               [IO.Path]::GetFullPath($Path) -ieq $script:AmmarTradingCloudFilesIdentityMutationPath) {
                return [pscustomobject]@{
                    FileAttributes = $metadata.FileAttributes
                    ReparseTag = [uint32]$metadata.ReparseTag
                    VolumeSerialNumber = [uint32]$metadata.VolumeSerialNumber
                    FileIndex = [uint64]($metadata.FileIndex + 1)
                }
            }
            return $metadata
        }
        $script:AmmarTradingTrustedPathOperationHook = {
            param($Description,$Path)
            if($Description -ceq 'Identity mutation seam') {
                $script:AmmarTradingCloudFilesIdentityMutationArmed = $true
            }
        }
    } $identityMutationDirectory
    Assert-ThrowsLike -Expected 'identity changed' -Action {
        & $setupModule {
            param($Root,$Path)
            Invoke-AmmarTradingTrustedPathOperation -OneDriveRoot $Root -Path @($Path) -Description 'Identity mutation seam' -Action {
                $script:AmmarTradingCloudFilesProtectedActionRan = $true
            } | Out-Null
        } $trustedRoot $identityMutationDirectory
    }
    $protectedActionRan = & $setupModule { $script:AmmarTradingCloudFilesProtectedActionRan }
    Assert-True -Condition (-not $protectedActionRan) -Message 'A changed held-path identity must fail before the protected action executes.'
    $identityMutationMoved = "$identityMutationDirectory.moved"
    Move-Item -LiteralPath $identityMutationDirectory -Destination $identityMutationMoved -ErrorAction Stop
    Move-Item -LiteralPath $identityMutationMoved -Destination $identityMutationDirectory -ErrorAction Stop

    # Real Windows integration: held component handles deny rename and delete
    # during the critical section, then deterministic disposal releases both.
    & $setupModule {
        param($LockPath)
        $script:AmmarTradingHeldPathMetadataResolver = $null
        $script:AmmarTradingCloudFilesLockPath = [IO.Path]::GetFullPath($LockPath)
        $script:AmmarTradingCloudFilesLockMovedPath = "$($script:AmmarTradingCloudFilesLockPath).moved"
        $script:AmmarTradingCloudFilesRenameBlocked = $false
        $script:AmmarTradingCloudFilesDeleteBlocked = $false
        $script:AmmarTradingTrustedPathOperationHook = {
            param($Description,$Path)
            if($Description -cne 'Windows held-handle integration') { return }
            try {
                Move-Item -LiteralPath $script:AmmarTradingCloudFilesLockPath -Destination $script:AmmarTradingCloudFilesLockMovedPath -ErrorAction Stop
            } catch {
                $script:AmmarTradingCloudFilesRenameBlocked =
                    (Test-Path -LiteralPath $script:AmmarTradingCloudFilesLockPath -PathType Container) -and
                    -not (Test-Path -LiteralPath $script:AmmarTradingCloudFilesLockMovedPath)
            }
            try {
                Remove-Item -LiteralPath $script:AmmarTradingCloudFilesLockPath -Recurse -Force -ErrorAction Stop
            } catch {
                $script:AmmarTradingCloudFilesDeleteBlocked = Test-Path -LiteralPath $script:AmmarTradingCloudFilesLockPath -PathType Container
            }
        }
    } $handleLockDirectory
    & $setupModule {
        param($Root,$Path)
        Invoke-AmmarTradingTrustedPathOperation -OneDriveRoot $Root -Path @($Path) -Description 'Windows held-handle integration' -Action {} | Out-Null
    } $trustedRoot $handleLockDirectory
    $lockResults = & $setupModule {
        [pscustomobject]@{
            RenameBlocked = $script:AmmarTradingCloudFilesRenameBlocked
            DeleteBlocked = $script:AmmarTradingCloudFilesDeleteBlocked
        }
    }
    Assert-True -Condition ([bool]$lockResults.RenameBlocked) -Message 'A held validated Windows handle must block rename replacement during the critical section.'
    Assert-True -Condition ([bool]$lockResults.DeleteBlocked) -Message 'A held validated Windows handle must block deletion during the critical section.'
    $handleLockMoved = "$handleLockDirectory.moved"
    Move-Item -LiteralPath $handleLockDirectory -Destination $handleLockMoved -ErrorAction Stop
    Remove-Item -LiteralPath $handleLockMoved -Recurse -Force -ErrorAction Stop
    Assert-True -Condition (-not (Test-Path -LiteralPath $handleLockMoved)) -Message 'Rename and deletion must be permitted after held handles are disposed.'
    & $setupModule {
        $script:AmmarTradingTrustedPathOperationHook = $null
        $script:AmmarTradingHeldPathMetadataResolver = $null
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

    # Duplicate registry rows that canonicalize to one root are one registration,
    # and resolution must consume the same immutable sample used for eligibility.
    & $setupModule {
        param($RegisteredRoot)
        $script:AmmarTradingCloudFilesTestRegisteredRoots = @($RegisteredRoot,(Join-Path $RegisteredRoot '.'))
        $script:AmmarTradingCloudFilesTestRegistrationCalls = 0
    } $trustedRoot
    $duplicateRoots = @(& $setupModule { @(Get-AmmarTradingWritableOneDriveRoots) })
    Assert-True -Condition ($duplicateRoots.Count -eq 1) -Message 'Duplicate account rows for one canonical root must be deduplicated.'
    $enumerationSamples = & $setupModule { $script:AmmarTradingCloudFilesTestRegistrationCalls }
    Assert-True -Condition ($enumerationSamples -eq 1) -Message 'A public root enumeration must obtain exactly one registration snapshot.'
    & $setupModule { $script:AmmarTradingCloudFilesTestRegistrationCalls = 0 }
    $duplicateResolved = Resolve-AmmarTradingOneDriveRoot -Path $trustedRoot -RequireWritable
    Assert-True -Condition ($duplicateResolved -ceq [IO.Path]::GetFullPath($trustedRoot)) -Message 'Duplicate account rows for one canonical root must resolve.'
    $resolutionSamples = & $setupModule { $script:AmmarTradingCloudFilesTestRegistrationCalls }
    Assert-True -Condition ($resolutionSamples -eq 1) -Message 'A public root resolution must obtain exactly one registration snapshot.'

    # A resolver mutation after its first sample cannot change authorization or
    # writability decisions within the same resolution operation.
    & $setupModule {
        param($FirstRoot,$SecondRoot)
        $script:AmmarTradingCloudFilesTestRegisteredRoots = @($FirstRoot)
        $script:AmmarTradingCloudFilesTestMutatedRoots = @($SecondRoot)
        $script:AmmarTradingCloudFilesTestRegistrationCalls = 0
        $script:AmmarTradingOneDriveRegistrationResolver = {
            $script:AmmarTradingCloudFilesTestRegistrationCalls++
            if($script:AmmarTradingCloudFilesTestRegistrationCalls -eq 1) {
                return @($script:AmmarTradingCloudFilesTestRegisteredRoots)
            }
            return @($script:AmmarTradingCloudFilesTestMutatedRoots)
        }
    } $trustedRoot $secondaryRoot
    $mutationResolved = Resolve-AmmarTradingOneDriveRoot -Path $trustedRoot -RequireWritable
    Assert-True -Condition ($mutationResolved -ceq [IO.Path]::GetFullPath($trustedRoot)) -Message 'Resolution must remain authorized against its first immutable registration snapshot.'
    $mutationSamples = & $setupModule { $script:AmmarTradingCloudFilesTestRegistrationCalls }
    Assert-True -Condition ($mutationSamples -eq 1) -Message 'A changing resolver must not be sampled twice by one resolution.'

    & $setupModule {
        param($FirstRoot,$SecondRoot)
        $script:AmmarTradingCloudFilesTestRegistrationCalls = 0
        $script:AmmarTradingCloudFilesTestRegisteredRoots = @($FirstRoot,$SecondRoot)
        $script:AmmarTradingOneDriveRegistrationResolver = {
            $script:AmmarTradingCloudFilesTestRegistrationCalls++
            @($script:AmmarTradingCloudFilesTestRegisteredRoots)
        }
    } $trustedRoot $secondaryRoot
    $registeredRoots = @(& $setupModule { @(Get-AmmarTradingWritableOneDriveRoots) })
    Assert-True -Condition ($registeredRoots.Count -eq 2) -Message 'Each current-user OneDrive account registration must be considered.'
    Assert-True -Condition ([bool]($registeredRoots | Where-Object { $_.Path -ieq [IO.Path]::GetFullPath($trustedRoot) -and $_.IsActive })) -Message 'An exact environment hint must mark its registered root active.'
    Assert-True -Condition (-not [bool]($registeredRoots | Where-Object { $_.Path -ieq [IO.Path]::GetFullPath($secondaryRoot) -and $_.IsActive })) -Message 'An unmatched registered root must not be marked active.'
    $secondaryResolved = Resolve-AmmarTradingOneDriveRoot -Path $secondaryRoot -RequireWritable
    Assert-True -Condition ($secondaryResolved -ceq [IO.Path]::GetFullPath($secondaryRoot)) -Message 'A second registered OneDrive account root must resolve.'

    # An existing registration without an exact environment activity hint stays
    # eligible but inactive; activity hints are not an authorization source.
    $env:OneDrive = $trustedRoot
    $env:OneDriveCommercial = ''
    $env:OneDriveConsumer = ''
    & $setupModule {
        param($RegisteredRoot)
        $script:AmmarTradingCloudFilesTestRegisteredRoots = @($RegisteredRoot)
    } $secondaryRoot
    $existingStaleRoots = @(& $setupModule { @(Get-AmmarTradingWritableOneDriveRoots) })
    Assert-True -Condition ($existingStaleRoots.Count -eq 1) -Message 'An existing registered root without an activity hint must remain eligible.'
    Assert-True -Condition (-not [bool]$existingStaleRoots[0].IsActive) -Message 'An existing registered root without an exact activity hint must be inactive.'
    $existingStaleResolved = Resolve-AmmarTradingOneDriveRoot -Path $secondaryRoot -RequireWritable
    Assert-True -Condition ($existingStaleResolved -ceq [IO.Path]::GetFullPath($secondaryRoot)) -Message 'An existing inactive registration must still resolve.'

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
