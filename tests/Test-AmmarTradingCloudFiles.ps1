[CmdletBinding()]
param(
    [string]$SetupModulePath,
    [string]$SyncScriptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if([string]::IsNullOrWhiteSpace($SetupModulePath)) {
    $SetupModulePath = Join-Path $PSScriptRoot '..\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1'
}
if([string]::IsNullOrWhiteSpace($SyncScriptPath)) {
    $SyncScriptPath = Join-Path (Split-Path -Parent $SetupModulePath) 'Sync-BasketsToOneDrive.ps1'
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

function Assert-NoPublicationTemporaryFile {
    param([Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$Message)
    $prefix = [IO.Path]::GetFileName($Destination) + '.'
    $temporary = @(Get-ChildItem -LiteralPath (Split-Path -Parent $Destination) -File -Force -ErrorAction Stop |
        Where-Object { $_.Name.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and $_.Name.EndsWith('.tmp',[StringComparison]::OrdinalIgnoreCase) })
    if($temporary.Count -ne 0) { throw $Message }
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
    $setupModuleText = Get-Content -LiteralPath $SetupModulePath -Raw -ErrorAction Stop
    Assert-True -Condition ($setupModuleText -match 'NativeErrorCode -notin @\(32,80,183\)') -Message 'Legacy migration must resolve OneDrive materialization races reported as sharing violations by comparing destination bytes.'
    Assert-True -Condition ($setupModuleText -match 'CreateFile\(\$Path, \[uint32\]3221291392, \[uint32\]0x1, \[IntPtr\]::Zero, \[uint32\]1, \[uint32\]0x80,') -Message 'A create-new publication handle must target the newly created file itself without FILE_FLAG_OPEN_REPARSE_POINT, which Cloud Files cannot rename.'
    Assert-True -Condition ($setupModuleText -match 'Invoke-AmmarTradingHeldFileRenameWithRetry') -Message 'Cloud Files sharing violations must be retried while the verified file handle remains authoritative.'
    Assert-True -Condition ($setupModuleText -notmatch '\[IO\.File\]::Move\(\$temporary,\$canonicalDestination\)') -Message 'Cloud Files compatibility must not fall back to an unheld pathname move.'
    Assert-True -Condition ($setupModuleText -match 'Invoke-AmmarTradingCanonicalPublicationOperation') -Message 'Publication must keep the immediate destination-directory identity held without locking Cloud Files ancestors.'
    Assert-True -Condition ($setupModuleText -match '(?s)Assert-AmmarTradingHeldPathLocksUnchanged.+Invoke-AmmarTradingHeldFileRenameWithRetry') -Message 'Publication must revalidate the held destination directory immediately before its atomic rename.'
    $renameRetryAttempts = & $setupModule {
        $script:AmmarTradingCloudFilesRenameRetryAttempts = 0
        $script:AmmarTradingHeldFileRenameHook = {
            param($Handle,$Destination,$ReplaceIfExists,$Attempt)
            $script:AmmarTradingCloudFilesRenameRetryAttempts++
            if($Attempt -lt 3) { throw [ComponentModel.Win32Exception]::new(32) }
        }
        try {
            Invoke-AmmarTradingHeldFileRenameWithRetry -Handle ([object]::new()) -Destination 'test-only' -MaximumAttempts 3 -RetryDelayMilliseconds 0
            return $script:AmmarTradingCloudFilesRenameRetryAttempts
        } finally {
            $script:AmmarTradingHeldFileRenameHook = $null
            Remove-Variable -Name AmmarTradingCloudFilesRenameRetryAttempts -Scope Script -ErrorAction SilentlyContinue
        }
    }
    Assert-True -Condition ($renameRetryAttempts -eq 3) -Message 'A transient sharing violation must be retried and then succeed on the same held handle.'
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

    # A regular file substituted after the temporary bytes are written but
    # before publication must never become the destination. Both trusted
    # writers exercise the real sync functions; the hook targets the gap that
    # existed between their write/copy operation and pathname re-open.
    & $setCloudFilesTag $trustedRoot ([Convert]::ToUInt32('9000701A',16))
    $setupModuleObject = $setupModule
    . $SyncScriptPath -AsLibrary -RuntimeRoot (Join-Path $testRoot 'sync-runtime')
    $setupModule = $setupModuleObject
    $publicationDirectory = New-AmmarTradingTrustedDirectory -OneDriveRoot $trustedRoot -Path (Join-Path $trustedRoot 'Publication') -Description 'Cloud Files publication test directory'
    $textDestination = Join-Path $publicationDirectory 'status.json'
    $csvSource = Join-Path $publicationDirectory 'source.csv'
    $csvDestination = Join-Path $publicationDirectory 'Baskets.csv'

    # Failure paths must preserve the old destination and remove only the
    # unpublished file created by this operation.
    $abcState = [pscustomobject]@{ Bytes=[Text.Encoding]::UTF8.GetBytes('abc') }
    $abcSha256 = 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'
    $callbackDestination = Join-Path $publicationDirectory 'callback-failure.txt'
    [IO.File]::WriteAllText($callbackDestination, 'callback-original', (New-Object Text.UTF8Encoding($false)))
    Assert-ThrowsLike -Expected 'callback write failure' -Action {
        Publish-AmmarTradingTrustedFile -OneDriveRoot $trustedRoot -Destination $callbackDestination -Description 'Callback failure publication' -ExpectedLength 3 -ExpectedSha256 $abcSha256 -WriteState $abcState -ReplaceIfExists -WriteAction {
            param($Stream,$State)
            $Stream.Write([byte[]]$State.Bytes,0,$State.Bytes.Length)
            throw 'callback write failure'
        } | Out-Null
    }
    Assert-True -Condition ((Get-Content -LiteralPath $callbackDestination -Raw) -ceq 'callback-original') -Message 'A publication callback failure must preserve the prior destination bytes.'
    Assert-NoPublicationTemporaryFile -Destination $callbackDestination -Message 'A publication callback failure must delete its unpublished task-created temporary file.'

    $hashMismatchDestination = Join-Path $publicationDirectory 'hash-mismatch.txt'
    [IO.File]::WriteAllText($hashMismatchDestination, 'hash-original', (New-Object Text.UTF8Encoding($false)))
    Assert-ThrowsLike -Expected 'content verification failed' -Action {
        Publish-AmmarTradingTrustedFile -OneDriveRoot $trustedRoot -Destination $hashMismatchDestination -Description 'Hash mismatch publication' -ExpectedLength 3 -ExpectedSha256 ('0' * 64) -WriteState $abcState -ReplaceIfExists -WriteAction {
            param($Stream,$State)
            $Stream.Write([byte[]]$State.Bytes,0,$State.Bytes.Length)
        } | Out-Null
    }
    Assert-True -Condition ((Get-Content -LiteralPath $hashMismatchDestination -Raw) -ceq 'hash-original') -Message 'A temporary hash mismatch must fail before replacing the destination.'
    Assert-NoPublicationTemporaryFile -Destination $hashMismatchDestination -Message 'A hash mismatch must delete its unpublished task-created temporary file.'

    $renameFailureDestination = Join-Path $publicationDirectory 'rename-failure-target'
    New-Item -ItemType Directory -Path $renameFailureDestination -Force | Out-Null
    Assert-ThrowsLike -Expected 'could not be renamed atomically by handle' -Action {
        Publish-AmmarTradingTrustedFile -OneDriveRoot $trustedRoot -Destination $renameFailureDestination -Description 'Rename failure publication' -ExpectedLength 3 -ExpectedSha256 $abcSha256 -WriteState $abcState -ReplaceIfExists -WriteAction {
            param($Stream,$State)
            $Stream.Write([byte[]]$State.Bytes,0,$State.Bytes.Length)
        } | Out-Null
    }
    Assert-True -Condition (Test-Path -LiteralPath $renameFailureDestination -PathType Container) -Message 'A failed handle rename must preserve the existing destination object.'
    Assert-NoPublicationTemporaryFile -Destination $renameFailureDestination -Message 'A rename failure must delete its unpublished task-created temporary file.'

    # Once a replacing rename succeeds, a fallible destination metadata check
    # must report its error without deleting the held file at its new namespace.
    $postRenameVerificationDestination = Join-Path $publicationDirectory 'post-rename-verification-failure.txt'
    [IO.File]::WriteAllText($postRenameVerificationDestination, 'verification-original', (New-Object Text.UTF8Encoding($false)))
    & $setupModule {
        param($Destination)
        $script:AmmarTradingCloudFilesPostRenameFailureDestination = [IO.Path]::GetFullPath($Destination)
        $script:AmmarTradingHeldPathMetadataResolver = {
            param($Handle,$Path)
            if([IO.Path]::GetFullPath([string]$Path) -ieq $script:AmmarTradingCloudFilesPostRenameFailureDestination) {
                throw 'deterministic post-rename destination verification failure'
            }
            return Get-AmmarTradingNativeHandleMetadata -Handle $Handle
        }
    } $postRenameVerificationDestination
    try {
        Assert-ThrowsLike -Expected 'deterministic post-rename destination verification failure' -Action {
            Publish-AmmarTradingTrustedFile -OneDriveRoot $trustedRoot -Destination $postRenameVerificationDestination -Description 'Post-rename verification failure publication' -ExpectedLength 3 -ExpectedSha256 $abcSha256 -WriteState $abcState -ReplaceIfExists -WriteAction {
                param($Stream,$State)
                $Stream.Write([byte[]]$State.Bytes,0,$State.Bytes.Length)
            } | Out-Null
        }
    } finally {
        & $setupModule {
            $script:AmmarTradingHeldPathMetadataResolver = $null
            Remove-Variable -Name AmmarTradingCloudFilesPostRenameFailureDestination -Scope Script -ErrorAction SilentlyContinue
        }
    }
    Assert-True -Condition (Test-Path -LiteralPath $postRenameVerificationDestination -PathType Leaf) -Message 'A post-rename destination verification failure must not delete-by-handle the published replacement.'
    Assert-True -Condition ((Get-Content -LiteralPath $postRenameVerificationDestination -Raw) -ceq 'abc') -Message 'A post-rename destination verification failure must retain the verified replacement bytes.'
    Assert-NoPublicationTemporaryFile -Destination $postRenameVerificationDestination -Message 'A post-rename destination verification failure must not leave an unpublished temporary file.'

    # A mismatch on the required fourth, post-rename hash must report failure
    # without treating the published replacement as an unpublished temp.
    $postRenameHashMismatchDestination = Join-Path $publicationDirectory 'post-rename-hash-mismatch.txt'
    [IO.File]::WriteAllText($postRenameHashMismatchDestination, 'hash-mismatch-original', (New-Object Text.UTF8Encoding($false)))
    $originalOpenStreamSha256 = & $setupModule { ${function:Get-AmmarTradingOpenStreamSha256} }
    try {
        & $setupModule {
            param($OriginalOpenStreamSha256)
            $script:AmmarTradingCloudFilesOriginalOpenStreamSha256 = $OriginalOpenStreamSha256
            $script:AmmarTradingCloudFilesOpenStreamSha256Calls = 0
            function script:Get-AmmarTradingOpenStreamSha256 {
                param([Parameter(Mandatory)][IO.FileStream]$Stream)
                $script:AmmarTradingCloudFilesOpenStreamSha256Calls++
                if($script:AmmarTradingCloudFilesOpenStreamSha256Calls -eq 4) { return ('0' * 64) }
                return & $script:AmmarTradingCloudFilesOriginalOpenStreamSha256 -Stream $Stream
            }
        } $originalOpenStreamSha256
        Assert-ThrowsLike -Expected 'content verification failed after publication' -Action {
            Publish-AmmarTradingTrustedFile -OneDriveRoot $trustedRoot -Destination $postRenameHashMismatchDestination -Description 'Post-rename hash mismatch publication' -ExpectedLength 3 -ExpectedSha256 $abcSha256 -WriteState $abcState -ReplaceIfExists -WriteAction {
                param($Stream,$State)
                $Stream.Write([byte[]]$State.Bytes,0,$State.Bytes.Length)
            } | Out-Null
        }
    } finally {
        & $setupModule {
            param($OriginalOpenStreamSha256)
            Set-Item -LiteralPath Function:Get-AmmarTradingOpenStreamSha256 -Value $OriginalOpenStreamSha256
            Remove-Variable -Name AmmarTradingCloudFilesOriginalOpenStreamSha256,AmmarTradingCloudFilesOpenStreamSha256Calls -Scope Script -ErrorAction SilentlyContinue
        } $originalOpenStreamSha256
    }
    Assert-True -Condition ((Get-Content -LiteralPath $postRenameHashMismatchDestination -Raw) -ceq 'abc') -Message 'A post-rename hash mismatch must retain the verified replacement destination.'
    Assert-NoPublicationTemporaryFile -Destination $postRenameHashMismatchDestination -Message 'A post-rename hash mismatch must not leave an unpublished temporary file.'

    # A hash read failure on the required fourth, post-rename read must report
    # failure without treating the published replacement as an unpublished temp.
    $postRenameHashFailureDestination = Join-Path $publicationDirectory 'post-rename-hash-failure.txt'
    [IO.File]::WriteAllText($postRenameHashFailureDestination, 'hash-read-original', (New-Object Text.UTF8Encoding($false)))
    $originalOpenStreamSha256 = & $setupModule { ${function:Get-AmmarTradingOpenStreamSha256} }
    try {
        & $setupModule {
            param($OriginalOpenStreamSha256)
            $script:AmmarTradingCloudFilesOriginalOpenStreamSha256 = $OriginalOpenStreamSha256
            $script:AmmarTradingCloudFilesOpenStreamSha256Calls = 0
            function script:Get-AmmarTradingOpenStreamSha256 {
                param([Parameter(Mandatory)][IO.FileStream]$Stream)
                $script:AmmarTradingCloudFilesOpenStreamSha256Calls++
                if($script:AmmarTradingCloudFilesOpenStreamSha256Calls -eq 4) {
                    throw 'deterministic post-rename hash read failure'
                }
                return & $script:AmmarTradingCloudFilesOriginalOpenStreamSha256 -Stream $Stream
            }
        } $originalOpenStreamSha256
        Assert-ThrowsLike -Expected 'deterministic post-rename hash read failure' -Action {
            Publish-AmmarTradingTrustedFile -OneDriveRoot $trustedRoot -Destination $postRenameHashFailureDestination -Description 'Post-rename hash failure publication' -ExpectedLength 3 -ExpectedSha256 $abcSha256 -WriteState $abcState -ReplaceIfExists -WriteAction {
                param($Stream,$State)
                $Stream.Write([byte[]]$State.Bytes,0,$State.Bytes.Length)
            } | Out-Null
        }
    } finally {
        & $setupModule {
            param($OriginalOpenStreamSha256)
            Set-Item -LiteralPath Function:Get-AmmarTradingOpenStreamSha256 -Value $OriginalOpenStreamSha256
            Remove-Variable -Name AmmarTradingCloudFilesOriginalOpenStreamSha256,AmmarTradingCloudFilesOpenStreamSha256Calls -Scope Script -ErrorAction SilentlyContinue
        } $originalOpenStreamSha256
    }
    Assert-True -Condition ((Get-Content -LiteralPath $postRenameHashFailureDestination -Raw) -ceq 'abc') -Message 'A post-rename hash read failure must retain the verified replacement destination.'
    Assert-NoPublicationTemporaryFile -Destination $postRenameHashFailureDestination -Message 'A post-rename hash read failure must not leave an unpublished temporary file.'

    # Real Windows sharing integration: the verified temp leaf must deny an
    # in-place writer with otherwise fully compatible share flags, rename,
    # deletion, and regular-file replacement until the publishing handle is
    # disposed. The renamed destination must be freely mutable afterward.
    $heldDestination = Join-Path $publicationDirectory 'held-temp.txt'
    $heldReplacement = Join-Path $publicationDirectory 'held-temp-attacker.txt'
    [IO.File]::WriteAllText($heldReplacement, 'attacker-replacement', (New-Object Text.UTF8Encoding($false)))
    & $setupModule {
        param($Replacement)
        $script:AmmarTradingCloudFilesHeldReplacement = $Replacement
        $script:AmmarTradingCloudFilesHeldRenameBlocked = $false
        $script:AmmarTradingCloudFilesHeldDeleteBlocked = $false
        $script:AmmarTradingCloudFilesHeldReplaceBlocked = $false
        $script:AmmarTradingCloudFilesHeldWriteBlocked = $false
        $script:AmmarTradingCloudFilesHeldWriteSucceeded = $false
        $script:AmmarTradingTrustedFilePublicationHook = {
            param($Description,$Temporary,$Destination)
            if($Description -cne 'Held temporary Windows integration') { return }
            $writer = $null
            try {
                $writer = [IO.FileStream]::new($Temporary,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]7)
                $writer.Write([byte[]]@(97),0,1)
                $writer.Flush($true)
                $script:AmmarTradingCloudFilesHeldWriteSucceeded = $true
            } catch {
                $script:AmmarTradingCloudFilesHeldWriteBlocked = Test-Path -LiteralPath $Temporary -PathType Leaf
            } finally {
                if($null -ne $writer) { $writer.Dispose() }
            }
            try { Move-Item -LiteralPath $Temporary -Destination "$Temporary.moved" -ErrorAction Stop }
            catch { $script:AmmarTradingCloudFilesHeldRenameBlocked = (Test-Path -LiteralPath $Temporary -PathType Leaf) }
            try { Remove-Item -LiteralPath $Temporary -Force -ErrorAction Stop }
            catch { $script:AmmarTradingCloudFilesHeldDeleteBlocked = (Test-Path -LiteralPath $Temporary -PathType Leaf) }
            try { [IO.File]::Replace($script:AmmarTradingCloudFilesHeldReplacement,$Temporary,"$Temporary.backup",$true) }
            catch { $script:AmmarTradingCloudFilesHeldReplaceBlocked = (Test-Path -LiteralPath $Temporary -PathType Leaf) }
        }
    } $heldReplacement
    $heldPublication = Publish-AmmarTradingTrustedFile -OneDriveRoot $trustedRoot -Destination $heldDestination -Description 'Held temporary Windows integration' -ExpectedLength 3 -ExpectedSha256 $abcSha256 -WriteState $abcState -ReplaceIfExists -WriteAction {
        param($Stream,$State)
        $Stream.Write([byte[]]$State.Bytes,0,$State.Bytes.Length)
    }
    $heldResults = & $setupModule {
        [pscustomobject]@{
            RenameBlocked = $script:AmmarTradingCloudFilesHeldRenameBlocked
            DeleteBlocked = $script:AmmarTradingCloudFilesHeldDeleteBlocked
            ReplaceBlocked = $script:AmmarTradingCloudFilesHeldReplaceBlocked
            WriteBlocked = $script:AmmarTradingCloudFilesHeldWriteBlocked
            WriteSucceeded = $script:AmmarTradingCloudFilesHeldWriteSucceeded
        }
    }
    Assert-True -Condition ([bool]$heldResults.WriteBlocked -and -not [bool]$heldResults.WriteSucceeded) -Message 'The held verified temporary leaf must block a real Windows in-place write open with full share flags.'
    Assert-True -Condition ([bool]$heldResults.RenameBlocked) -Message 'The held verified temporary leaf must block a real Windows rename attempt.'
    Assert-True -Condition ([bool]$heldResults.DeleteBlocked) -Message 'The held verified temporary leaf must block a real Windows deletion attempt.'
    Assert-True -Condition ([bool]$heldResults.ReplaceBlocked) -Message 'The held verified temporary leaf must block a real Windows regular-file replacement attempt.'
    Assert-True -Condition ((Get-Content -LiteralPath $heldDestination -Raw) -ceq 'abc') -Message 'The held-handle integration must publish only the verified bytes.'
    Assert-True -Condition ([string]$heldPublication.Hash -ceq (Get-FileHash -LiteralPath $heldDestination -Algorithm SHA256).Hash) -Message 'A successful publication must return the final destination SHA-256 computed from its held handle.'
    $postDisposalWriter = [IO.FileStream]::new($heldDestination,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]7)
    try {
        $postDisposalWriter.Write([byte[]]@(97),0,1)
        $postDisposalWriter.Flush($true)
    } finally {
        $postDisposalWriter.Dispose()
    }
    Assert-True -Condition ((Get-Content -LiteralPath $heldDestination -Raw) -ceq 'abc') -Message 'A real Windows in-place write open must succeed after the publication handle is disposed.'
    [IO.File]::WriteAllText($heldReplacement, 'post-disposal-replacement', (New-Object Text.UTF8Encoding($false)))
    $heldPostDisposalBackup = "$heldDestination.post-replace.bak"
    [IO.File]::Replace($heldReplacement,$heldDestination,$heldPostDisposalBackup,$true)
    Remove-Item -LiteralPath $heldPostDisposalBackup -Force -ErrorAction Stop
    $heldMovedDestination = "$heldDestination.moved"
    Move-Item -LiteralPath $heldDestination -Destination $heldMovedDestination -ErrorAction Stop
    Remove-Item -LiteralPath $heldMovedDestination -Force -ErrorAction Stop
    Assert-True -Condition (-not (Test-Path -LiteralPath $heldMovedDestination)) -Message 'The temporary publication handle must be disposed after success with no rename/delete leak.'
    & $setupModule { $script:AmmarTradingTrustedFilePublicationHook = $null }

    [IO.File]::WriteAllText($textDestination, 'old-text', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($csvSource, 'trusted-csv-bytes', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($csvDestination, 'old-csv', (New-Object Text.UTF8Encoding($false)))
    & $setupModule {
        param($TextDestination,$CsvDestination)
        $script:AmmarTradingCloudFilesPublicationDestinations = @{
            'Atomic text publication' = [IO.Path]::GetFullPath($TextDestination)
            'Atomic CSV publication' = [IO.Path]::GetFullPath($CsvDestination)
        }
        $script:AmmarTradingCloudFilesSubstitutionSucceeded = 0
        $script:AmmarTradingCloudFilesSubstitutionBlocked = 0
        $script:AmmarTradingCloudFilesPublicationAttackHook = {
            param($Description,$Path,$Destination)
            if(-not $script:AmmarTradingCloudFilesPublicationDestinations.ContainsKey($Description)) { return }
            $expectedDestination = [string]$script:AmmarTradingCloudFilesPublicationDestinations[$Description]
            $temporary = $null
            if(-not [string]::IsNullOrWhiteSpace([string]$Destination) -and
               [IO.Path]::GetFullPath([string]$Destination) -ieq $expectedDestination -and
               (Test-Path -LiteralPath ([string]$Path) -PathType Leaf)) {
                $temporary = [string]$Path
            } else {
                $prefix = [IO.Path]::GetFileName($expectedDestination) + '.'
                $temporaryItem = @(Get-ChildItem -LiteralPath (Split-Path -Parent $expectedDestination) -File -Force -ErrorAction Stop |
                    Where-Object { $_.Name.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and $_.Name.EndsWith('.tmp',[StringComparison]::OrdinalIgnoreCase) } |
                    Select-Object -First 1)
                if($temporaryItem.Count -eq 1) { $temporary = [string]$temporaryItem[0].FullName }
            }
            if([string]::IsNullOrWhiteSpace($temporary)) { return }
            try {
                Move-Item -LiteralPath $temporary -Destination "$temporary.verified" -ErrorAction Stop
                [IO.File]::WriteAllText($temporary, 'attacker-bytes', (New-Object Text.UTF8Encoding($false)))
                $script:AmmarTradingCloudFilesSubstitutionSucceeded++
            } catch {
                $script:AmmarTradingCloudFilesSubstitutionBlocked++
            }
        }
        $script:AmmarTradingTrustedPathOperationHook = $script:AmmarTradingCloudFilesPublicationAttackHook
        $script:AmmarTradingTrustedFilePublicationHook = $script:AmmarTradingCloudFilesPublicationAttackHook
    } $textDestination $csvDestination

    Write-AtomicText -Path $textDestination -Content 'trusted-text-bytes' -TrustedOneDriveRoot $trustedRoot
    Publish-AtomicFile -Source $csvSource -Destination $csvDestination -TrustedOneDriveRoot $trustedRoot
    $publicationAttack = & $setupModule {
        [pscustomobject]@{
            Succeeded = $script:AmmarTradingCloudFilesSubstitutionSucceeded
            Blocked = $script:AmmarTradingCloudFilesSubstitutionBlocked
        }
    }
    Assert-True -Condition ($publicationAttack.Succeeded -eq 0 -and $publicationAttack.Blocked -eq 2) -Message 'A verified temporary regular file must remain held so text and CSV pathname substitution is blocked before publication.'
    Assert-True -Condition ((Get-Content -LiteralPath $textDestination -Raw) -ceq 'trusted-text-bytes') -Message 'Atomic text publication must never install attacker bytes substituted after verification.'
    Assert-True -Condition ((Get-Content -LiteralPath $csvDestination -Raw) -ceq 'trusted-csv-bytes') -Message 'Atomic CSV publication must never install attacker bytes substituted after verification.'
    & $setupModule {
        $script:AmmarTradingTrustedPathOperationHook = $null
        $script:AmmarTradingTrustedFilePublicationHook = $null
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
