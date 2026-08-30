Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AmmarTradingDriveTypeResolver = {
    param([Parameter(Mandatory)][string]$VolumeRoot)
    return (New-Object IO.DriveInfo($VolumeRoot)).DriveType
}
$script:AmmarTradingOneDriveRegistrationResolver = {
    $accountsPath = 'HKCU:\Software\Microsoft\OneDrive\Accounts'
    if(-not (Test-Path -LiteralPath $accountsPath -PathType Container)) { return @() }

    $roots = [System.Collections.Generic.List[string]]::new()
    foreach($account in @(Get-ChildItem -LiteralPath $accountsPath -ErrorAction Stop)) {
        try {
            $userFolder = [string](Get-ItemPropertyValue -LiteralPath $account.PSPath -Name 'UserFolder' -ErrorAction Stop)
            if(-not [string]::IsNullOrWhiteSpace($userFolder)) { $roots.Add($userFolder) }
        } catch {
            # An incomplete account registration is not a trusted root.
        }
    }
    return @($roots)
}
$script:AmmarTradingRunningTerminalPathResolver = {
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach($process in @([Diagnostics.Process]::GetProcessesByName('terminal'))) {
        try {
            $executablePath = [string]$process.MainModule.FileName
            if(-not [string]::IsNullOrWhiteSpace($executablePath)) { $paths.Add($executablePath) }
        } catch {
        } finally {
            $process.Dispose()
        }
    }
    return @($paths)
}
$script:AmmarTradingTaskInstallerInvoker = {
    param(
        [Parameter(Mandatory)][string]$Installer,
        [Parameter(Mandatory)][string]$ConfigPath
    )
    & $Installer -ConfigPath $ConfigPath
}
$script:AmmarTradingHeldPathMetadataResolver = $null
$script:AmmarTradingTrustedPathOperationHook = $null
$script:AmmarTradingTrustedFilePublicationHook = $null
$script:AmmarTradingHeldFileRenameHook = $null
$script:AmmarTradingCurrentPathOperationContext = $null
$script:AmmarTradingFileAttributeTagResolver = {
    param([Parameter(Mandatory)][string]$Path)

    if($null -eq ('AmmarTrading.NativeFileInfo' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;

namespace AmmarTrading {
    public static class NativeFileInfo {
        [StructLayout(LayoutKind.Sequential)]
        public struct FileAttributeTagInfo {
            public UInt32 FileAttributes;
            public UInt32 ReparseTag;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct NativeFileTime {
            public UInt32 LowDateTime;
            public UInt32 HighDateTime;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct ByHandleFileInformation {
            public UInt32 FileAttributes;
            public NativeFileTime CreationTime;
            public NativeFileTime LastAccessTime;
            public NativeFileTime LastWriteTime;
            public UInt32 VolumeSerialNumber;
            public UInt32 FileSizeHigh;
            public UInt32 FileSizeLow;
            public UInt32 NumberOfLinks;
            public UInt32 FileIndexHigh;
            public UInt32 FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern SafeFileHandle CreateFile(
            string fileName,
            UInt32 desiredAccess,
            UInt32 shareMode,
            IntPtr securityAttributes,
            UInt32 creationDisposition,
            UInt32 flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetFileInformationByHandleEx(
            SafeFileHandle file,
            Int32 fileInformationClass,
            out FileAttributeTagInfo fileInformation,
            UInt32 bufferSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out ByHandleFileInformation fileInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFileInformationByHandle(
            SafeFileHandle file,
            Int32 fileInformationClass,
            IntPtr fileInformation,
            UInt32 bufferSize);

        public static void RenameByHandle(SafeFileHandle file, SafeFileHandle rootDirectory, string destination, bool replaceIfExists) {
            char[] name = destination.ToCharArray();
            int rootOffset = IntPtr.Size == 8 ? 8 : 4;
            int lengthOffset = IntPtr.Size == 8 ? 16 : 8;
            int nameOffset = IntPtr.Size == 8 ? 20 : 12;
            int bufferSize = nameOffset + (name.Length * 2) + 2;
            IntPtr buffer = Marshal.AllocHGlobal(bufferSize);
            try {
                for(int index = 0; index < bufferSize; index++) { Marshal.WriteByte(buffer, index, 0); }
                Marshal.WriteInt32(buffer, 0, replaceIfExists ? 1 : 0);
                Marshal.WriteIntPtr(buffer, rootOffset, rootDirectory == null ? IntPtr.Zero : rootDirectory.DangerousGetHandle());
                Marshal.WriteInt32(buffer, lengthOffset, name.Length * 2);
                Marshal.Copy(name, 0, IntPtr.Add(buffer, nameOffset), name.Length);
                if(!SetFileInformationByHandle(file, 3, buffer, (UInt32)bufferSize)) {
                    int error = Marshal.GetLastWin32Error();
                    throw new System.ComponentModel.Win32Exception(error, "The trusted file could not be renamed atomically by handle (Win32 " + error + ").");
                }
            } finally {
                Marshal.FreeHGlobal(buffer);
            }
        }

        public static void DeleteByHandle(SafeFileHandle file) {
            IntPtr buffer = Marshal.AllocHGlobal(1);
            try {
                Marshal.WriteByte(buffer, 0, 1);
                if(!SetFileInformationByHandle(file, 4, buffer, 1)) {
                    int error = Marshal.GetLastWin32Error();
                    throw new System.ComponentModel.Win32Exception(error, "The unpublished trusted file could not be deleted by handle (Win32 " + error + ").");
                }
            } finally {
                Marshal.FreeHGlobal(buffer);
            }
        }
    }
}
'@ -ErrorAction Stop
    }

    # FILE_READ_ATTRIBUTES, FILE_SHARE_READ|WRITE|DELETE, OPEN_EXISTING,
    # FILE_FLAG_BACKUP_SEMANTICS, and FILE_FLAG_OPEN_REPARSE_POINT.
    $handle = [AmmarTrading.NativeFileInfo]::CreateFile($Path, [uint32]0x80, [uint32]0x7, [IntPtr]::Zero, [uint32]3, [uint32]0x02200000, [IntPtr]::Zero)
    if($handle.IsInvalid) { throw 'The reparse point could not be opened for tag inspection.' }
    try {
        $info = New-Object AmmarTrading.NativeFileInfo+FileAttributeTagInfo
        $size = [uint32][Runtime.InteropServices.Marshal]::SizeOf($info)
        if(-not [AmmarTrading.NativeFileInfo]::GetFileInformationByHandleEx($handle, 9, [ref]$info, $size)) {
            throw 'The reparse point tag could not be inspected.'
        }
        return [pscustomobject]@{
            FileAttributes = [IO.FileAttributes][uint32]$info.FileAttributes
            ReparseTag = [uint32]$info.ReparseTag
        }
    } finally {
        $handle.Dispose()
    }
}

function Test-AmmarTradingUncPath {
    param([Parameter(Mandatory)][string]$Path)
    return $Path -match '^(?:[^:]+::)?[\\/]{2}'
}

function Test-AmmarTradingCloudFilesReparseTag {
    param([Parameter(Mandatory)][uint32]$Tag)

    return ('{0:X8}' -f $Tag) -in @(
        '9000001A','9000101A','9000201A','9000301A',
        '9000401A','9000501A','9000601A','9000701A',
        '9000801A','9000901A','9000A01A','9000B01A',
        '9000C01A','9000D01A','9000E01A','9000F01A'
    )
}

function Test-AmmarTradingPathBelow {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $canonicalPath = [IO.Path]::GetFullPath($Path)
    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    return $canonicalPath -ieq $canonicalRoot -or $canonicalPath.StartsWith($canonicalRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Get-AmmarTradingFileAttributeTagInfo {
    param([Parameter(Mandatory)][string]$Path)

    $result = & $script:AmmarTradingFileAttributeTagResolver $Path
    if($null -eq $result -or -not $result.PSObject.Properties['FileAttributes'] -or -not $result.PSObject.Properties['ReparseTag'] -or
       $null -eq $result.FileAttributes -or $null -eq $result.ReparseTag) {
        throw 'The file attribute and reparse tag metadata could not be inspected.'
    }
    return [pscustomobject]@{
        FileAttributes = [IO.FileAttributes]$result.FileAttributes
        ReparseTag = [uint32]$result.ReparseTag
    }
}

function Open-AmmarTradingPathHandle {
    param(
        [Parameter(Mandatory)][string]$Path,
        [uint32]$DesiredAccess = [uint32]0x80,
        [uint32]$ShareMode = [uint32]0x3
    )

    if($null -eq ('AmmarTrading.NativeFileInfo' -as [type])) {
        # Initialize the bounded native type through the existing real resolver.
        [void](& $script:AmmarTradingFileAttributeTagResolver $Path)
    }
    # FILE_SHARE_READ|FILE_SHARE_WRITE deliberately omits FILE_SHARE_DELETE so
    # the validated object cannot be renamed or replaced while the handle lives.
    $handle = [AmmarTrading.NativeFileInfo]::CreateFile($Path, $DesiredAccess, $ShareMode, [IntPtr]::Zero, [uint32]3, [uint32]0x02200000, [IntPtr]::Zero)
    if($handle.IsInvalid) {
        $handle.Dispose()
        throw "A trusted path component could not be held for identity validation: $Path"
    }
    return $handle
}

function Open-AmmarTradingNewFileHandle {
    param([Parameter(Mandatory)][string]$Path)

    if($null -eq ('AmmarTrading.NativeFileInfo' -as [type])) {
        $parent = Split-Path -Parent $Path
        [void](& $script:AmmarTradingFileAttributeTagResolver $parent)
    }
    # GENERIC_READ|GENERIC_WRITE|DELETE|FILE_READ_ATTRIBUTES|FILE_WRITE_ATTRIBUTES,
    # FILE_SHARE_READ, CREATE_NEW, and FILE_ATTRIBUTE_NORMAL. The path cannot
    # pre-exist because CREATE_NEW is mandatory, so OPEN_REPARSE_POINT adds no
    # substitution protection and prevents Cloud Files from renaming the held
    # new file. Write and delete sharing remain deliberately omitted.
    $handle = [AmmarTrading.NativeFileInfo]::CreateFile($Path, [uint32]3221291392, [uint32]0x1, [IntPtr]::Zero, [uint32]1, [uint32]0x80, [IntPtr]::Zero)
    if($handle.IsInvalid) {
        $nativeError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $handle.Dispose()
        throw [ComponentModel.Win32Exception]::new($nativeError, "The trusted temporary file could not be created with create-new semantics (Win32 $nativeError).")
    }
    return $handle
}

function Get-AmmarTradingNativeHandleMetadata {
    param([Parameter(Mandatory)]$Handle)

    $attributeTag = New-Object AmmarTrading.NativeFileInfo+FileAttributeTagInfo
    $attributeTagSize = [uint32][Runtime.InteropServices.Marshal]::SizeOf($attributeTag)
    if(-not [AmmarTrading.NativeFileInfo]::GetFileInformationByHandleEx($Handle, 9, [ref]$attributeTag, $attributeTagSize)) {
        throw 'A held path component attribute/tag snapshot could not be inspected.'
    }
    $identity = New-Object AmmarTrading.NativeFileInfo+ByHandleFileInformation
    if(-not [AmmarTrading.NativeFileInfo]::GetFileInformationByHandle($Handle, [ref]$identity)) {
        throw 'A held path component identity could not be inspected.'
    }
    $fileIndex = ([uint64]$identity.FileIndexHigh * [uint64]4294967296) + [uint64]$identity.FileIndexLow
    return [pscustomobject]@{
        FileAttributes = [IO.FileAttributes][uint32]$attributeTag.FileAttributes
        ReparseTag = [uint32]$attributeTag.ReparseTag
        VolumeSerialNumber = [uint32]$identity.VolumeSerialNumber
        FileIndex = [uint64]$fileIndex
    }
}

function Get-AmmarTradingHeldPathMetadata {
    param(
        [Parameter(Mandatory)]$Handle,
        [Parameter(Mandatory)][string]$Path
    )

    $result = if($null -ne $script:AmmarTradingHeldPathMetadataResolver) {
        & $script:AmmarTradingHeldPathMetadataResolver $Handle $Path
    } else {
        Get-AmmarTradingNativeHandleMetadata -Handle $Handle
    }
    foreach($required in @('FileAttributes','ReparseTag','VolumeSerialNumber','FileIndex')) {
        if($null -eq $result -or -not $result.PSObject.Properties[$required] -or $null -eq $result.$required) {
            throw 'A held path component metadata snapshot was incomplete.'
        }
    }
    return [pscustomobject]@{
        FileAttributes = [IO.FileAttributes]$result.FileAttributes
        ReparseTag = [uint32]$result.ReparseTag
        VolumeSerialNumber = [uint32]$result.VolumeSerialNumber
        FileIndex = [uint64]$result.FileIndex
    }
}

function Assert-AmmarTradingHeldPathMetadataInvariant {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Metadata,
        [Parameter(Mandatory)][string]$TrustedCloudFilesRoot,
        [Parameter(Mandatory)][string]$Description
    )

    $isReparse = ($Metadata.FileAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    if(-not $isReparse) {
        if([uint32]$Metadata.ReparseTag -ne 0) { throw "$Description contains inconsistent reparse metadata." }
        return
    }
    $tag = [uint32]$Metadata.ReparseTag
    if(-not (Test-AmmarTradingPathBelow -Path $Path -Root $TrustedCloudFilesRoot)) {
        throw "$Description contains a reparse point."
    }
    if(($tag -band [uint32]0x20000000) -ne 0 -or -not (Test-AmmarTradingCloudFilesReparseTag -Tag $tag)) {
        throw "$Description contains an unsupported reparse point."
    }
}

function Test-AmmarTradingHeldPathMetadataMatch {
    param([Parameter(Mandatory)]$Expected,[Parameter(Mandatory)]$Actual)

    $expectedReparse = ($Expected.FileAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    $actualReparse = ($Actual.FileAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    return [uint32]$Expected.VolumeSerialNumber -eq [uint32]$Actual.VolumeSerialNumber -and
           [uint64]$Expected.FileIndex -eq [uint64]$Actual.FileIndex -and
           $expectedReparse -eq $actualReparse -and
           [uint32]$Expected.ReparseTag -eq [uint32]$Actual.ReparseTag
}

function Add-AmmarTradingHeldPathLocks {
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Locks,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Seen,
        [Parameter(Mandatory)][string]$TrustedCloudFilesRoot,
        [Parameter(Mandatory)][string]$Description
    )

    foreach($requestedPath in @($Path)) {
        $fullPath = [IO.Path]::GetFullPath($requestedPath)
        if(-not (Test-AmmarTradingPathBelow -Path $fullPath -Root $TrustedCloudFilesRoot)) {
            throw "$Description must remain below the trusted OneDrive root."
        }
        $volumeRoot = [IO.Path]::GetPathRoot($fullPath)
        $components = [System.Collections.Generic.List[string]]::new()
        $components.Add($volumeRoot)
        $current = $volumeRoot
        foreach($part in @($fullPath.Substring($volumeRoot.Length) -split '[\\/]')) {
            if([string]::IsNullOrWhiteSpace($part)) { continue }
            $current = Join-Path $current $part
            $components.Add($current)
        }
        foreach($component in $components) {
            $canonicalComponent = [IO.Path]::GetFullPath($component)
            if($Seen.Contains($canonicalComponent)) { continue }
            if(-not (Test-Path -LiteralPath $canonicalComponent)) { break }
            $handle = $null
            try {
                $isRequestedLeaf = $canonicalComponent -ieq $fullPath
                $isDirectory = Test-Path -LiteralPath $canonicalComponent -PathType Container
                $requiresDeleteLock = (Test-AmmarTradingPathBelow -Path $canonicalComponent -Root $TrustedCloudFilesRoot) -and
                                      (-not $isRequestedLeaf -or $isDirectory)
                $desiredAccess = if($requiresDeleteLock) { [uint32]0x00010080 } else { [uint32]0x80 }
                $handle = Open-AmmarTradingPathHandle -Path $canonicalComponent -DesiredAccess $desiredAccess
                $metadata = Get-AmmarTradingHeldPathMetadata -Handle $handle -Path $canonicalComponent
                Assert-AmmarTradingHeldPathMetadataInvariant -Path $canonicalComponent -Metadata $metadata -TrustedCloudFilesRoot $TrustedCloudFilesRoot -Description $Description
                $Locks.Add([pscustomobject]@{ Path=$canonicalComponent; Handle=$handle; Initial=$metadata })
                [void]$Seen.Add($canonicalComponent)
                $handle = $null
            } finally {
                if($null -ne $handle) { $handle.Dispose() }
            }
        }
    }
}

function Assert-AmmarTradingHeldPathLocksUnchanged {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Locks,
        [Parameter(Mandatory)][string]$TrustedCloudFilesRoot,
        [Parameter(Mandatory)][string]$Description
    )

    foreach($lock in $Locks) {
        $current = Get-AmmarTradingHeldPathMetadata -Handle $lock.Handle -Path $lock.Path
        Assert-AmmarTradingHeldPathMetadataInvariant -Path $lock.Path -Metadata $current -TrustedCloudFilesRoot $TrustedCloudFilesRoot -Description $Description
        if(-not (Test-AmmarTradingHeldPathMetadataMatch -Expected $lock.Initial -Actual $current)) {
            throw "$Description identity changed while the trusted path operation was protected."
        }
        $pathHandle = $null
        try {
            # FILE_SHARE_DELETE is required only for this inspection handle to
            # coexist with our own DELETE-access lock; it never replaces the lock.
            $pathHandle = Open-AmmarTradingPathHandle -Path $lock.Path -ShareMode ([uint32]0x7)
            $pathMetadata = Get-AmmarTradingHeldPathMetadata -Handle $pathHandle -Path $lock.Path
            Assert-AmmarTradingHeldPathMetadataInvariant -Path $lock.Path -Metadata $pathMetadata -TrustedCloudFilesRoot $TrustedCloudFilesRoot -Description $Description
            if(-not (Test-AmmarTradingHeldPathMetadataMatch -Expected $lock.Initial -Actual $pathMetadata)) {
                throw "$Description identity changed while the trusted path operation was protected."
            }
        } catch {
            if($_.Exception.Message -match 'identity changed|reparse|metadata') { throw }
            throw "$Description identity changed while the trusted path operation was protected."
        } finally {
            if($null -ne $pathHandle) { $pathHandle.Dispose() }
        }
    }
}

function Invoke-AmmarTradingCanonicalPathOperation {
    param(
        [Parameter(Mandatory)][string]$CanonicalOneDriveRoot,
        [Parameter(Mandatory)][string[]]$Path,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    $canonicalRoot = [IO.Path]::GetFullPath($CanonicalOneDriveRoot)
    $volumeRoot = [IO.Path]::GetPathRoot($canonicalRoot)
    try { $driveType = & $script:AmmarTradingDriveTypeResolver $volumeRoot }
    catch { throw "$Description local filesystem volume could not be verified." }
    if([IO.DriveType]$driveType -ne [IO.DriveType]::Fixed) { throw "$Description must use a local fixed filesystem volume." }

    $locks = [System.Collections.Generic.List[object]]::new()
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    try {
        Add-AmmarTradingHeldPathLocks -Path $Path -Locks $locks -Seen $seen -TrustedCloudFilesRoot $canonicalRoot -Description $Description
        if($null -ne $script:AmmarTradingTrustedPathOperationHook) { & $script:AmmarTradingTrustedPathOperationHook $Description @($Path) }
        Assert-AmmarTradingHeldPathLocksUnchanged -Locks $locks -TrustedCloudFilesRoot $canonicalRoot -Description $Description
        $result = @(& $Action)
        Add-AmmarTradingHeldPathLocks -Path $Path -Locks $locks -Seen $seen -TrustedCloudFilesRoot $canonicalRoot -Description $Description
        Assert-AmmarTradingHeldPathLocksUnchanged -Locks $locks -TrustedCloudFilesRoot $canonicalRoot -Description $Description
        return $result
    } finally {
        for($index = $locks.Count - 1; $index -ge 0; $index--) {
            $locks[$index].Handle.Dispose()
        }
    }
}

function Assert-AmmarTradingNoReparseAncestors {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description,
        [string]$TrustedCloudFilesRoot = ''
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $volumeRoot = [IO.Path]::GetPathRoot($fullPath)
    if([string]::IsNullOrWhiteSpace($volumeRoot)) { throw "$Description must use a local filesystem volume." }
    $current = $volumeRoot
    foreach($part in @($fullPath.Substring($volumeRoot.Length) -split '[\\/]')) {
        if([string]::IsNullOrWhiteSpace($part)) { continue }
        $current = Join-Path $current $part
        if(-not (Test-Path -LiteralPath $current)) { break }
        $metadata = Get-AmmarTradingFileAttributeTagInfo -Path $current
        if(($metadata.FileAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $tag = [uint32]$metadata.ReparseTag
            if([string]::IsNullOrWhiteSpace($TrustedCloudFilesRoot) -or
               -not (Test-AmmarTradingPathBelow -Path $current -Root $TrustedCloudFilesRoot)) {
                throw "$Description contains a reparse point."
            }
            # Exact Cloud Files tags are not name-surrogate tags; all name surrogates stay rejected.
            if(($tag -band [uint32]0x20000000) -ne 0) {
                throw "$Description contains an unsupported reparse point."
            }
            if(-not (Test-AmmarTradingCloudFilesReparseTag -Tag $tag)) {
                throw "$Description contains an unsupported reparse point."
            }
        } elseif([uint32]$metadata.ReparseTag -ne 0) {
            throw "$Description contains inconsistent reparse metadata."
        }
    }
}

function Resolve-AmmarTradingLocalPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Leaf','Container')][string]$PathType,
        [Parameter(Mandatory)][string]$Description,
        [string]$TrustedCloudFilesRoot = ''
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if([string]::IsNullOrWhiteSpace($expanded)) { throw "$Description is required." }
    if(Test-AmmarTradingUncPath -Path $expanded) { throw "$Description must use a local filesystem path; UNC paths are not allowed." }
    if(-not (Test-Path -LiteralPath $expanded -PathType $PathType)) { throw "$Description was not found: $expanded" }

    $resolved = Resolve-Path -LiteralPath $expanded -ErrorAction Stop
    if($resolved.Provider.Name -cne 'FileSystem') { throw "$Description must use a local filesystem path." }
    $providerPath = [string]$resolved.ProviderPath
    if(Test-AmmarTradingUncPath -Path $providerPath) { throw "$Description must use a local filesystem path; UNC paths are not allowed." }

    $drive = $resolved.Drive
    if($null -eq $drive) { throw "$Description must use a local filesystem volume." }
    $displayRoot = if($drive.PSObject.Properties['DisplayRoot']) { [string]$drive.DisplayRoot } else { '' }
    if(-not [string]::IsNullOrWhiteSpace($displayRoot) -and (Test-AmmarTradingUncPath -Path $displayRoot)) {
        throw "$Description must use a local filesystem volume; mapped network drives are not allowed."
    }

    $volumeRoot = [IO.Path]::GetPathRoot($providerPath)
    if([string]::IsNullOrWhiteSpace($volumeRoot)) { throw "$Description must use a local filesystem volume." }
    try {
        $driveType = & $script:AmmarTradingDriveTypeResolver $volumeRoot
    } catch {
        throw "$Description local filesystem volume could not be verified."
    }
    if([IO.DriveType]$driveType -eq [IO.DriveType]::Network) {
        throw "$Description must use a local filesystem volume; mapped network drives are not allowed."
    }
    if([IO.DriveType]$driveType -ne [IO.DriveType]::Fixed) {
        throw "$Description must use a local fixed filesystem volume."
    }

    Assert-AmmarTradingNoReparseAncestors -Path $providerPath -Description $Description -TrustedCloudFilesRoot $TrustedCloudFilesRoot

    return [IO.Path]::GetFullPath($providerPath)
}

function Get-AmmarTradingOneDriveRegistrationSnapshot {
    $sample = @(& $script:AmmarTradingOneDriveRegistrationResolver)
    $roots = [System.Collections.Generic.List[object]]::new()
    $rejected = [System.Collections.Generic.List[object]]::new()
    $canonicalCandidates = [System.Collections.Generic.List[string]]::new()
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($candidate in $sample) {
        if([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        try {
            $expanded = [Environment]::ExpandEnvironmentVariables(([string]$candidate).Trim())
            if(Test-AmmarTradingUncPath -Path $expanded) { continue }
            $canonical = [IO.Path]::GetFullPath($expanded)
        } catch {
            continue
        }
        if($seen.Add($canonical)) { $canonicalCandidates.Add($canonical) }
    }
    foreach($canonical in $canonicalCandidates) {
        try {
            $resolved = Resolve-AmmarTradingLocalPath -Path $canonical -PathType Container -Description 'OneDrive root' -TrustedCloudFilesRoot $canonical
            $roots.Add([pscustomobject]@{ Path = $resolved })
        } catch {
            $rejected.Add([pscustomobject]@{ Path=$canonical; Error=[string]$_.Exception.Message })
        }
    }
    return [pscustomobject]@{ Roots=@($roots); Rejected=@($rejected) }
}

function Get-AmmarTradingRegisteredOneDriveRoots {
    param($Snapshot = $null)

    if($null -eq $Snapshot) { $Snapshot = Get-AmmarTradingOneDriveRegistrationSnapshot }
    return @($Snapshot.Roots)
}

function Test-AmmarTradingOneDriveActivityHint {
    param([Parameter(Mandatory)][string]$RegisteredRoot)

    foreach($candidate in @($env:OneDrive,$env:OneDriveCommercial,$env:OneDriveConsumer)) {
        if([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        try {
            $hint = [Environment]::ExpandEnvironmentVariables(([string]$candidate).Trim())
            if(Test-AmmarTradingUncPath -Path $hint) { continue }
            if([IO.Path]::GetFullPath($hint) -ieq $RegisteredRoot) { return $true }
        } catch {
            continue
        }
    }
    return $false
}

function Get-AmmarTradingWritableOneDriveRootsFromSnapshot {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [string]$OnlyPath = ''
    )

    $roots = [System.Collections.Generic.List[object]]::new()
    foreach($registered in @(Get-AmmarTradingRegisteredOneDriveRoots -Snapshot $Snapshot)) {
        $resolved = [string]$registered.Path
        if(-not [string]::IsNullOrWhiteSpace($OnlyPath) -and $resolved -ine $OnlyPath) { continue }
        $probe = Join-Path $resolved (".$([guid]::NewGuid().ToString('N')).ammartrading-write-test.tmp")
        try {
            [void](Invoke-AmmarTradingCanonicalPathOperation -CanonicalOneDriveRoot $resolved -Path @($probe) -Description 'OneDrive write probe' -Action {
                [IO.File]::WriteAllText($probe, '', (New-Object Text.UTF8Encoding($false)))
            })
            $roots.Add([pscustomobject][ordered]@{
                Name = Split-Path -Leaf $resolved
                Path = $resolved
                Available = $true
                IsActive = Test-AmmarTradingOneDriveActivityHint -RegisteredRoot $resolved
                IsWritable = $true
            })
        } catch {
            # A signed-in root that cannot accept the bounded probe is not eligible.
        } finally {
            if(Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
        }
    }
    return @($roots)
}

function Get-AmmarTradingWritableOneDriveRoots {
    $snapshot = Get-AmmarTradingOneDriveRegistrationSnapshot
    return @(Get-AmmarTradingWritableOneDriveRootsFromSnapshot -Snapshot $snapshot)
}

function Resolve-AmmarTradingOneDriveRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$RequireWritable
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if([string]::IsNullOrWhiteSpace($expanded)) { throw 'OneDrive root is required.' }
    if(Test-AmmarTradingUncPath -Path $expanded) { throw 'OneDrive root must use a local filesystem path; UNC paths are not allowed.' }
    try {
        $requested = [IO.Path]::GetFullPath($expanded)
    } catch {
        throw 'OneDrive root must use a local filesystem path.'
    }
    $snapshot = Get-AmmarTradingOneDriveRegistrationSnapshot
    $registeredMatches = @($snapshot.Roots | Where-Object { $_.Path -ieq $requested })
    if($registeredMatches.Count -ne 1) {
        $rejectedMatch = @($snapshot.Rejected | Where-Object { $_.Path -ieq $requested } | Select-Object -First 1)
        if($rejectedMatch.Count -eq 1) { throw [string]$rejectedMatch[0].Error }
        throw 'OneDrive root must exactly match a currently signed-in OneDrive root.'
    }
    $registeredPath = [string]$registeredMatches[0].Path
    $matches = @(Get-AmmarTradingWritableOneDriveRootsFromSnapshot -Snapshot $snapshot -OnlyPath $registeredPath)
    if($matches.Count -ne 1) { throw 'OneDrive root must exactly match a currently signed-in OneDrive root.' }
    if($RequireWritable -and -not [bool]$matches[0].IsWritable) { throw 'OneDrive root is not writable.' }
    return [string]$matches[0].Path
}

function Invoke-AmmarTradingTrustedPathOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OneDriveRoot,
        [Parameter(Mandatory)][string[]]$Path,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    $canonicalRoot = Resolve-AmmarTradingOneDriveRoot -Path $OneDriveRoot -RequireWritable
    return Invoke-AmmarTradingCanonicalPathOperation -CanonicalOneDriveRoot $canonicalRoot -Path $Path -Description $Description -Action $Action
}

function Get-AmmarTradingOpenStreamSha256 {
    param([Parameter(Mandatory)][IO.FileStream]$Stream)

    $originalPosition = $Stream.Position
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        [void]$Stream.Seek(0,[IO.SeekOrigin]::Begin)
        $hash = $sha256.ComputeHash($Stream)
        return [BitConverter]::ToString($hash).Replace('-','')
    } finally {
        $sha256.Dispose()
        [void]$Stream.Seek($originalPosition,[IO.SeekOrigin]::Begin)
    }
}

function Assert-AmmarTradingHeldFileIdentityAtPath {
    param(
        [Parameter(Mandatory)]$Handle,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$ExpectedMetadata,
        [Parameter(Mandatory)][string]$TrustedCloudFilesRoot,
        [Parameter(Mandatory)][string]$Description
    )

    $heldMetadata = Get-AmmarTradingHeldPathMetadata -Handle $Handle -Path $Path
    Assert-AmmarTradingHeldPathMetadataInvariant -Path $Path -Metadata $heldMetadata -TrustedCloudFilesRoot $TrustedCloudFilesRoot -Description $Description
    if(-not (Test-AmmarTradingHeldPathMetadataMatch -Expected $ExpectedMetadata -Actual $heldMetadata)) {
        throw "$Description identity changed while its publication handle was held."
    }

    $pathHandle = $null
    try {
        # The inspection handle shares delete only so it can coexist with the
        # authoritative handle; it never becomes the rename authority.
        $pathHandle = Open-AmmarTradingPathHandle -Path $Path -ShareMode ([uint32]0x7)
        $pathMetadata = Get-AmmarTradingHeldPathMetadata -Handle $pathHandle -Path $Path
        Assert-AmmarTradingHeldPathMetadataInvariant -Path $Path -Metadata $pathMetadata -TrustedCloudFilesRoot $TrustedCloudFilesRoot -Description $Description
        if(-not (Test-AmmarTradingHeldPathMetadataMatch -Expected $ExpectedMetadata -Actual $pathMetadata)) {
            throw "$Description pathname no longer identifies the held publication file."
        }
    } catch {
        if($_.Exception.Message -match 'identity changed|pathname no longer identifies|reparse|metadata') { throw }
        throw "$Description pathname no longer identifies the held publication file."
    } finally {
        if($null -ne $pathHandle) { $pathHandle.Dispose() }
    }
    return $heldMetadata
}

function Invoke-AmmarTradingHeldFileRenameWithRetry {
    param(
        [Parameter(Mandatory)]$Handle,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$ReplaceIfExists,
        [ValidateRange(1,240)][int]$MaximumAttempts = 80,
        [ValidateRange(0,5000)][int]$RetryDelayMilliseconds = 250
    )

    for($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            if($null -ne $script:AmmarTradingHeldFileRenameHook) {
                & $script:AmmarTradingHeldFileRenameHook $Handle $Destination ([bool]$ReplaceIfExists) $attempt | Out-Null
            } else {
                [AmmarTrading.NativeFileInfo]::RenameByHandle($Handle,$null,$Destination,[bool]$ReplaceIfExists)
            }
            return
        } catch {
            $renameFailure = $_.Exception
            while($null -ne $renameFailure.InnerException) { $renameFailure = $renameFailure.InnerException }
            if($renameFailure -isnot [ComponentModel.Win32Exception] -or
               $renameFailure.NativeErrorCode -ne 32 -or
               $attempt -ge $MaximumAttempts) {
                throw
            }
            if($RetryDelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $RetryDelayMilliseconds }
        }
    }
}

function Invoke-AmmarTradingCanonicalPublicationOperation {
    param(
        [Parameter(Mandatory)][string]$CanonicalOneDriveRoot,
        [Parameter(Mandatory)][string]$DestinationDirectory,
        [Parameter(Mandatory)][string[]]$ValidatedPath,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    $canonicalRoot = [IO.Path]::GetFullPath($CanonicalOneDriveRoot)
    $canonicalDirectory = Assert-AmmarTradingCanonicalDestinationPath -CanonicalOneDriveRoot $canonicalRoot -Path $DestinationDirectory -Description "$Description destination directory"
    $directoryHandle = $null
    $previousOperationContext = $script:AmmarTradingCurrentPathOperationContext
    try {
        # Cloud Files rejects child renames while any ancestor handles are open.
        # Hold only the immediate destination directory for identity checks.
        $directoryHandle = Open-AmmarTradingPathHandle -Path $canonicalDirectory -DesiredAccess ([uint32]0x80) -ShareMode ([uint32]0x7)
        $directoryMetadata = Get-AmmarTradingHeldPathMetadata -Handle $directoryHandle -Path $canonicalDirectory
        Assert-AmmarTradingHeldPathMetadataInvariant -Path $canonicalDirectory -Metadata $directoryMetadata -TrustedCloudFilesRoot $canonicalRoot -Description "$Description destination directory"
        [void](Assert-AmmarTradingHeldFileIdentityAtPath -Handle $directoryHandle -Path $canonicalDirectory -ExpectedMetadata $directoryMetadata -TrustedCloudFilesRoot $canonicalRoot -Description "$Description destination directory")
        if($null -ne $script:AmmarTradingTrustedPathOperationHook) {
            & $script:AmmarTradingTrustedPathOperationHook $Description @($ValidatedPath) | Out-Null
        }
        [void](Assert-AmmarTradingHeldFileIdentityAtPath -Handle $directoryHandle -Path $canonicalDirectory -ExpectedMetadata $directoryMetadata -TrustedCloudFilesRoot $canonicalRoot -Description "$Description destination directory")
        $locks = [System.Collections.Generic.List[object]]::new()
        $locks.Add([pscustomobject]@{ Path=$canonicalDirectory; Handle=$directoryHandle; Initial=$directoryMetadata })
        $script:AmmarTradingCurrentPathOperationContext = [pscustomobject]@{ Locks=$locks }
        $result = @(& $Action)
        [void](Assert-AmmarTradingHeldFileIdentityAtPath -Handle $directoryHandle -Path $canonicalDirectory -ExpectedMetadata $directoryMetadata -TrustedCloudFilesRoot $canonicalRoot -Description "$Description destination directory")
        return $result
    } finally {
        $script:AmmarTradingCurrentPathOperationContext = $previousOperationContext
        if($null -ne $directoryHandle) { $directoryHandle.Dispose() }
    }
}

function Publish-AmmarTradingCanonicalTrustedFile {
    param(
        [Parameter(Mandatory)][string]$CanonicalOneDriveRoot,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][int64]$ExpectedLength,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][scriptblock]$WriteAction,
        $WriteState = $null,
        [string[]]$AdditionalLockedPath = @(),
        [switch]$ReplaceIfExists
    )

    if($ExpectedLength -lt 0) { throw "$Description expected length must be zero or greater." }
    $normalizedExpectedHash = $ExpectedSha256.Trim().Replace('-','').ToUpperInvariant()
    if($normalizedExpectedHash -notmatch '^[0-9A-F]{64}$') { throw "$Description expected SHA-256 is invalid." }

    $canonicalRoot = [IO.Path]::GetFullPath($CanonicalOneDriveRoot)
    $canonicalDestination = Assert-AmmarTradingCanonicalDestinationPath -CanonicalOneDriveRoot $canonicalRoot -Path $Destination -Description "$Description destination"
    $destinationDirectory = Split-Path -Parent $canonicalDestination
    if(-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) { throw "$Description destination directory was not found." }
    $stagingCandidate = Join-Path ([IO.Path]::GetTempPath()) 'AmmarTrading\Publication'
    [void][IO.Directory]::CreateDirectory($stagingCandidate)
    $stagingDirectory = Resolve-AmmarTradingLocalPath -Path $stagingCandidate -PathType Container -Description "$Description staging directory"
    if([IO.Path]::GetPathRoot($stagingDirectory) -ine [IO.Path]::GetPathRoot($canonicalDestination)) {
        throw "$Description staging directory must use the same local volume as its destination."
    }

    $protectedPaths = [System.Collections.Generic.List[string]]::new()
    $protectedPaths.Add($destinationDirectory)
    foreach($lockedPath in @($AdditionalLockedPath)) {
        # Validate caller-supplied source paths against the same trust root,
        # but do not retain directory/file namespace locks through the final
        # destination rename. Cloud Files treats those unrelated source locks
        # as a sharing conflict. The writer opens the source without write or
        # delete sharing and the staged bytes must still match the caller's
        # expected length and SHA-256 before and after the publication hook.
        [void](Assert-AmmarTradingCanonicalDestinationPath -CanonicalOneDriveRoot $canonicalRoot -Path $lockedPath -Description "$Description protected path")
    }

    $result = @(Invoke-AmmarTradingCanonicalPublicationOperation -CanonicalOneDriveRoot $canonicalRoot -DestinationDirectory $destinationDirectory -ValidatedPath @($protectedPaths) -Description $Description -Action {
        $destinationDirectoryHandle = $null
        foreach($heldLock in @($script:AmmarTradingCurrentPathOperationContext.Locks)) {
            if([IO.Path]::GetFullPath([string]$heldLock.Path) -ieq $destinationDirectory) {
                $destinationDirectoryHandle = $heldLock.Handle
                break
            }
        }
        if($null -eq $destinationDirectoryHandle -or $destinationDirectoryHandle.IsInvalid -or $destinationDirectoryHandle.IsClosed) {
            throw "$Description destination directory handle is unavailable."
        }
        # Stage outside the Cloud Files namespace so OneDrive cannot acquire a
        # persistent non-delete-sharing handle before the atomic held-handle
        # rename. The staging directory itself is held against substitution,
        # and the file remains create-new, identity-bound, and hash-verified.
        $temporary = Join-Path $stagingDirectory ("$([IO.Path]::GetFileName($canonicalDestination)).$([guid]::NewGuid().ToString('N')).publication.tmp")
        $stagingDirectoryHandle = $null
        $temporaryHandle = $null
        $temporaryStream = $null
        $initialMetadata = $null
        $publicationResult = $null
        $operationFailure = $null
        $cleanupFailure = $null
        $namespaceChanged = $false
        try {
            # Directory delete sharing is required to move its held child out;
            # the child file handle itself continues to deny write/delete sharing.
            $stagingDirectoryHandle = Open-AmmarTradingPathHandle -Path $stagingDirectory -ShareMode ([uint32]0x7)
            $stagingMetadata = Get-AmmarTradingHeldPathMetadata -Handle $stagingDirectoryHandle -Path $stagingDirectory
            Assert-AmmarTradingHeldPathMetadataInvariant -Path $stagingDirectory -Metadata $stagingMetadata -TrustedCloudFilesRoot $canonicalRoot -Description "$Description staging directory"
            [void](Assert-AmmarTradingHeldFileIdentityAtPath -Handle $stagingDirectoryHandle -Path $stagingDirectory -ExpectedMetadata $stagingMetadata -TrustedCloudFilesRoot $canonicalRoot -Description "$Description staging directory")
            $temporaryHandle = Open-AmmarTradingNewFileHandle -Path $temporary
            $temporaryStream = [IO.FileStream]::new($temporaryHandle,[IO.FileAccess]::ReadWrite,4096,$false)
            $initialMetadata = Get-AmmarTradingHeldPathMetadata -Handle $temporaryHandle -Path $temporary
            Assert-AmmarTradingHeldPathMetadataInvariant -Path $temporary -Metadata $initialMetadata -TrustedCloudFilesRoot $canonicalRoot -Description "$Description temporary file"

            & $WriteAction $temporaryStream $WriteState | Out-Null
            $temporaryStream.Flush($true)
            [void](Assert-AmmarTradingHeldFileIdentityAtPath -Handle $temporaryHandle -Path $temporary -ExpectedMetadata $initialMetadata -TrustedCloudFilesRoot $canonicalRoot -Description "$Description temporary file")
            $actualLength = [int64]$temporaryStream.Length
            $actualHash = Get-AmmarTradingOpenStreamSha256 -Stream $temporaryStream
            if($actualLength -ne $ExpectedLength -or $actualHash -cne $normalizedExpectedHash) {
                throw "$Description content verification failed before publication."
            }

            if($null -ne $script:AmmarTradingTrustedFilePublicationHook) {
                & $script:AmmarTradingTrustedFilePublicationHook $Description $temporary $canonicalDestination | Out-Null
            }

            # The hook models a concurrent actor after verification. Recheck
            # both identity and content before any destination namespace change.
            $temporaryStream.Flush($true)
            [void](Assert-AmmarTradingHeldFileIdentityAtPath -Handle $temporaryHandle -Path $temporary -ExpectedMetadata $initialMetadata -TrustedCloudFilesRoot $canonicalRoot -Description "$Description temporary file")
            $actualLength = [int64]$temporaryStream.Length
            $actualHash = Get-AmmarTradingOpenStreamSha256 -Stream $temporaryStream
            if($actualLength -ne $ExpectedLength -or $actualHash -cne $normalizedExpectedHash) {
                throw "$Description content verification failed before publication."
            }

            # Cloud Files rejects a handle-bound rename while the original
            # read/write handle is still active. Flush and close that writer,
            # then reacquire the same file identity with DELETE access. The
            # reopened handle denies write/delete sharing, so the final hash
            # check and rename remain bound to immutable verified bytes.
            $temporaryStream.Dispose()
            $temporaryStream = $null
            $temporaryHandle.Dispose()
            $temporaryHandle = $null
            $temporaryHandle = Open-AmmarTradingPathHandle -Path $temporary -DesiredAccess ([uint32]0x00010080) -ShareMode ([uint32]0x5)
            $reopenedMetadata = Get-AmmarTradingHeldPathMetadata -Handle $temporaryHandle -Path $temporary
            Assert-AmmarTradingHeldPathMetadataInvariant -Path $temporary -Metadata $reopenedMetadata -TrustedCloudFilesRoot $canonicalRoot -Description "$Description temporary file"
            if(-not (Test-AmmarTradingHeldPathMetadataMatch -Expected $initialMetadata -Actual $reopenedMetadata)) {
                throw "$Description temporary file identity changed before publication."
            }
            $verificationShare = [IO.FileShare]::Read -bor [IO.FileShare]::Delete
            $verificationStream = [IO.FileStream]::new($temporary,[IO.FileMode]::Open,[IO.FileAccess]::Read,$verificationShare)
            try {
                $actualLength = [int64]$verificationStream.Length
                $actualHash = Get-AmmarTradingOpenStreamSha256 -Stream $verificationStream
            } finally {
                $verificationStream.Dispose()
            }
            if($actualLength -ne $ExpectedLength -or $actualHash -cne $normalizedExpectedHash) {
                throw "$Description content verification failed before publication."
            }

            # OneDrive may inspect a newly materialized Cloud Files placeholder
            # with a non-delete-sharing handle for a short period. Retry only
            # that transient sharing violation while our verified file handle
            # remains open. Cloud Files rejects a RootDirectory-relative NT
            # rename, so revalidate the held immediate parent and use the
            # already-canonical absolute destination. The file operation is
            # still handle-bound; never fall back to a pathname move.
            Assert-AmmarTradingHeldPathLocksUnchanged -Locks $script:AmmarTradingCurrentPathOperationContext.Locks -TrustedCloudFilesRoot $canonicalRoot -Description $Description
            $extendedDestination = if($canonicalDestination.StartsWith('\\?\')) { $canonicalDestination } else { '\\?\' + $canonicalDestination }
            Invoke-AmmarTradingHeldFileRenameWithRetry -Handle $temporaryHandle -Destination $extendedDestination -ReplaceIfExists:$ReplaceIfExists
            $namespaceChanged = $true
            [void](Assert-AmmarTradingHeldFileIdentityAtPath -Handle $temporaryHandle -Path $canonicalDestination -ExpectedMetadata $initialMetadata -TrustedCloudFilesRoot $canonicalRoot -Description "$Description destination")
            $finalVerificationStream = [IO.FileStream]::new($canonicalDestination,[IO.FileMode]::Open,[IO.FileAccess]::Read,$verificationShare)
            try {
                $finalLength = [int64]$finalVerificationStream.Length
                $finalHash = Get-AmmarTradingOpenStreamSha256 -Stream $finalVerificationStream
            } finally {
                $finalVerificationStream.Dispose()
            }
            if($finalLength -ne $ExpectedLength -or $finalHash -cne $normalizedExpectedHash) {
                throw "$Description content verification failed after publication."
            }
            $publicationResult = [pscustomobject]@{
                Path = $canonicalDestination
                Length = $finalLength
                Hash = $finalHash
            }
        } catch {
            $operationFailure = $_.Exception
            if($null -ne $temporaryHandle -and -not $temporaryHandle.IsInvalid -and -not $temporaryHandle.IsClosed -and -not $namespaceChanged) {
                try { [AmmarTrading.NativeFileInfo]::DeleteByHandle($temporaryHandle) }
                catch { $cleanupFailure = $_.Exception }
            }
        } finally {
            if($null -ne $temporaryStream) {
                try { $temporaryStream.Dispose() }
                catch { if($null -eq $operationFailure) { $operationFailure = $_.Exception } }
            }
            if($null -ne $temporaryHandle) { $temporaryHandle.Dispose() }
            if($null -ne $stagingDirectoryHandle) { $stagingDirectoryHandle.Dispose() }
        }

        if($null -ne $cleanupFailure) {
            throw "$Description failed and its task-created unpublished temporary file could not be deleted by handle: $($cleanupFailure.Message)"
        }
        if($null -ne $operationFailure) { throw $operationFailure }
        return $publicationResult
    })
    return $result[0]
}

function Publish-AmmarTradingTrustedFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OneDriveRoot,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][int64]$ExpectedLength,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][scriptblock]$WriteAction,
        $WriteState = $null,
        [string[]]$AdditionalLockedPath = @(),
        [switch]$ReplaceIfExists
    )

    $canonicalRoot = Resolve-AmmarTradingOneDriveRoot -Path $OneDriveRoot -RequireWritable
    return Publish-AmmarTradingCanonicalTrustedFile -CanonicalOneDriveRoot $canonicalRoot -Destination $Destination -Description $Description -ExpectedLength $ExpectedLength -ExpectedSha256 $ExpectedSha256 -WriteAction $WriteAction -WriteState $WriteState -AdditionalLockedPath $AdditionalLockedPath -ReplaceIfExists:$ReplaceIfExists
}

function Move-AmmarTradingCanonicalTrustedFileByHandle {
    param(
        [Parameter(Mandatory)][string]$CanonicalOneDriveRoot,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Description,
        [switch]$ReplaceIfExists
    )

    $canonicalRoot = [IO.Path]::GetFullPath($CanonicalOneDriveRoot)
    $canonicalSource = Assert-AmmarTradingCanonicalDestinationPath -CanonicalOneDriveRoot $canonicalRoot -Path $Source -Description "$Description source"
    $canonicalDestination = Assert-AmmarTradingCanonicalDestinationPath -CanonicalOneDriveRoot $canonicalRoot -Path $Destination -Description "$Description destination"
    if(-not (Test-Path -LiteralPath $canonicalSource -PathType Leaf)) { throw "$Description source was not found." }
    $sourceDirectory = Split-Path -Parent $canonicalSource
    $destinationDirectory = Split-Path -Parent $canonicalDestination
    if($sourceDirectory -ine $destinationDirectory) { throw "$Description must remain within one trusted directory." }

    [void](Invoke-AmmarTradingCanonicalPathOperation -CanonicalOneDriveRoot $canonicalRoot -Path @($sourceDirectory,$destinationDirectory) -Description $Description -Action {
        # DELETE on this source handle authorizes the handle-bound rename. Its
        # share mode still omits delete, so no other actor can rename it first.
        $sourceHandle = Open-AmmarTradingPathHandle -Path $canonicalSource -DesiredAccess ([uint32]0x00010080)
        try {
            $sourceMetadata = Get-AmmarTradingHeldPathMetadata -Handle $sourceHandle -Path $canonicalSource
            Assert-AmmarTradingHeldPathMetadataInvariant -Path $canonicalSource -Metadata $sourceMetadata -TrustedCloudFilesRoot $canonicalRoot -Description "$Description source"
            if(Test-Path -LiteralPath $canonicalDestination) {
                $destinationHandle = Open-AmmarTradingPathHandle -Path $canonicalDestination
                try {
                    $destinationMetadata = Get-AmmarTradingHeldPathMetadata -Handle $destinationHandle -Path $canonicalDestination
                    Assert-AmmarTradingHeldPathMetadataInvariant -Path $canonicalDestination -Metadata $destinationMetadata -TrustedCloudFilesRoot $canonicalRoot -Description "$Description destination"
                } finally {
                    $destinationHandle.Dispose()
                }
            }

            $extendedDestination = if($canonicalDestination.StartsWith('\\?\')) { $canonicalDestination } else { '\\?\' + $canonicalDestination }
            [AmmarTrading.NativeFileInfo]::RenameByHandle($sourceHandle, $null, $extendedDestination, [bool]$ReplaceIfExists)
            if(-not (Test-Path -LiteralPath $canonicalDestination -PathType Leaf)) { throw "$Description handle-bound destination could not be confirmed." }
            $renamedMetadata = Get-AmmarTradingHeldPathMetadata -Handle $sourceHandle -Path $canonicalDestination
            Assert-AmmarTradingHeldPathMetadataInvariant -Path $canonicalDestination -Metadata $renamedMetadata -TrustedCloudFilesRoot $canonicalRoot -Description "$Description destination"
            if(-not (Test-AmmarTradingHeldPathMetadataMatch -Expected $sourceMetadata -Actual $renamedMetadata)) {
                throw "$Description identity changed during handle-bound publication."
            }

        } finally {
            $sourceHandle.Dispose()
        }
    })
    return $canonicalDestination
}

function Move-AmmarTradingTrustedFileByHandle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OneDriveRoot,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Description,
        [switch]$ReplaceIfExists
    )

    $canonicalRoot = Resolve-AmmarTradingOneDriveRoot -Path $OneDriveRoot -RequireWritable
    return Move-AmmarTradingCanonicalTrustedFileByHandle -CanonicalOneDriveRoot $canonicalRoot -Source $Source -Destination $Destination -Description $Description -ReplaceIfExists:$ReplaceIfExists
}

function Assert-AmmarTradingCanonicalDestinationPath {
    param(
        [Parameter(Mandatory)][string]$CanonicalOneDriveRoot,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
    )

    $canonicalRoot = [IO.Path]::GetFullPath($CanonicalOneDriveRoot)
    $canonicalPath = [IO.Path]::GetFullPath($Path)
    $rootPrefix = $canonicalRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if(-not $canonicalPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must remain below the trusted OneDrive root."
    }
    Assert-AmmarTradingNoReparseAncestors -Path $canonicalPath -Description $Description -TrustedCloudFilesRoot $canonicalRoot
    return $canonicalPath
}

function Assert-AmmarTradingTrustedDestinationPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OneDriveRoot,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
    )

    $canonicalRoot = Resolve-AmmarTradingOneDriveRoot -Path $OneDriveRoot
    return Assert-AmmarTradingCanonicalDestinationPath -CanonicalOneDriveRoot $canonicalRoot -Path $Path -Description $Description
}

function New-AmmarTradingTrustedDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OneDriveRoot,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
    )

    $canonicalRoot = Resolve-AmmarTradingOneDriveRoot -Path $OneDriveRoot -RequireWritable
    $canonicalPath = Assert-AmmarTradingCanonicalDestinationPath -CanonicalOneDriveRoot $canonicalRoot -Path $Path -Description $Description
    $relativePath = $canonicalPath.Substring($canonicalRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $current = $canonicalRoot
    foreach($part in @($relativePath -split '[\\/]')) {
        if([string]::IsNullOrWhiteSpace($part)) { continue }
        $current = Join-Path $current $part
        [void](Assert-AmmarTradingCanonicalDestinationPath -CanonicalOneDriveRoot $canonicalRoot -Path $current -Description $Description)
        [void](Invoke-AmmarTradingCanonicalPathOperation -CanonicalOneDriveRoot $canonicalRoot -Path @($current) -Description $Description -Action {
            if(Test-Path -LiteralPath $current) {
                if(-not (Test-Path -LiteralPath $current -PathType Container)) { throw "$Description is blocked by a non-directory path." }
            } else {
                [void][IO.Directory]::CreateDirectory($current)
            }
        })
    }
    return $canonicalPath
}

function Get-AmmarTradingDestinationPath {
    param(
        [Parameter(Mandatory)][string]$OneDriveRoot,
        [Parameter(Mandatory)][string]$AccountNumber
    )

    Join-Path $OneDriveRoot (Join-Path 'AmmarTrading' (Join-Path ("Account_{0}" -f $AccountNumber) 'Baskets.csv'))
}

function Get-AmmarTradingDiscoveryHash {
    param([Parameter(Mandatory)][string]$Fingerprint)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Fingerprint)
        $hash = $sha256.ComputeHash($bytes)
        return [BitConverter]::ToString($hash).Replace('-', '')
    } finally {
        $sha256.Dispose()
    }
}

function Get-AmmarTradingMt4Accounts {
    [CmdletBinding()]
    param(
        [string]$TerminalDataRoot,
        [AllowEmptyCollection()][string[]]$ManualCsv
    )

    if([string]::IsNullOrWhiteSpace($TerminalDataRoot)) {
        $TerminalDataRoot = Join-Path $env:APPDATA 'MetaQuotes\Terminal'
    }

    $schemaModule = Join-Path $PSScriptRoot 'MoneyMachineCsvSchemaV3.psm1'
    if(-not (Test-Path -LiteralPath $schemaModule -PathType Leaf)) { throw "Schema validator was not found: $schemaModule" }
    Import-Module -Name $schemaModule -ErrorAction Stop

    $candidates = [System.Collections.Generic.List[object]]::new()
    $seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $runningTerminalPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    try {
        foreach($runningPath in @(& $script:AmmarTradingRunningTerminalPathResolver)) {
            if([string]::IsNullOrWhiteSpace([string]$runningPath)) { continue }
            try { [void]$runningTerminalPaths.Add([IO.Path]::GetFullPath(([string]$runningPath).Trim())) } catch {}
        }
    } catch {
        $runningTerminalPaths.Clear()
    }

    $resolvedTerminalRoot = $null
    if(-not [string]::IsNullOrWhiteSpace($TerminalDataRoot)) {
        try { $resolvedTerminalRoot = Resolve-AmmarTradingLocalPath -Path $TerminalDataRoot -PathType Container -Description 'MT4 terminal data root' } catch { $resolvedTerminalRoot = $null }
    }
    if($null -ne $resolvedTerminalRoot) {
        foreach($terminal in @(Get-ChildItem -LiteralPath $resolvedTerminalRoot -Directory -ErrorAction SilentlyContinue | Sort-Object FullName)) {
            $csv = Join-Path $terminal.FullName 'MQL4\Files\AGOLD___Baskets.csv'
            try { $resolvedCsv = Resolve-AmmarTradingLocalPath -Path $csv -PathType Leaf -Description 'MT4 source CSV' } catch { continue }

            $terminalName = $terminal.Name
            $origin = Join-Path $terminal.FullName 'origin.txt'
            $originValue = ''
            if(Test-Path -LiteralPath $origin -PathType Leaf) {
                try {
                    $originValue = ([string](Get-Content -LiteralPath $origin -Raw -ErrorAction Stop)).Trim()
                    if(-not [string]::IsNullOrWhiteSpace($originValue)) { $terminalName = $originValue }
                } catch {
                    $terminalName = $terminal.Name
                }
            }

            if([string]::IsNullOrWhiteSpace($originValue)) { continue }
            try { $terminalExecutable = [IO.Path]::GetFullPath((Join-Path $originValue 'terminal.exe')) } catch { continue }
            if(-not $runningTerminalPaths.Contains($terminalExecutable)) { continue }

            if($seenPaths.Add($resolvedCsv)) {
                $candidates.Add([pscustomobject]@{
                    SourceCsv = $resolvedCsv
                    TerminalId = $terminal.Name
                    TerminalName = $terminalName
                })
            }
        }
    }

    foreach($manualPath in @($ManualCsv)) {
        if([string]::IsNullOrWhiteSpace([string]$manualPath)) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables(([string]$manualPath).Trim())
        if([IO.Path]::GetExtension($expanded) -ine '.csv') { continue }
        try { $resolvedCsv = Resolve-AmmarTradingLocalPath -Path $expanded -PathType Leaf -Description 'Manual source CSV' } catch { continue }
        if($seenPaths.Add($resolvedCsv)) {
            $candidates.Add([pscustomobject]@{
                SourceCsv = $resolvedCsv
                TerminalId = 'Manual'
                TerminalName = 'Manual CSV'
            })
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach($candidate in @($candidates | Sort-Object SourceCsv)) {
        $file = Get-Item -LiteralPath $candidate.SourceCsv -ErrorAction Stop
        $identity = Get-AmmarTradingCsvIdentity -Path $file.FullName
        $fingerprint = '{0}|{1}|{2}|{3}' -f $file.FullName,$identity.AccountNumber,$file.Length,$file.LastWriteTimeUtc.Ticks
        $discoveryId = Get-AmmarTradingDiscoveryHash -Fingerprint $fingerprint

        $freshness = 'Unknown'
        if($file.LastWriteTimeUtc -ne [DateTime]::MinValue) {
            $age = [DateTime]::UtcNow - $file.LastWriteTimeUtc
            $freshness = if($age.TotalMinutes -le 15) { 'Fresh' } else { 'Stale' }
        }

        $eligibility = if($identity.Status -ceq 'Ready') { 'Ready' } else { 'Blocked' }
        $results.Add([pscustomobject][ordered]@{
            DiscoveryId = $discoveryId
            AccountNumber = $identity.AccountNumber
            BrokerName = $identity.BrokerName
            TerminalId = $candidate.TerminalId
            TerminalName = $candidate.TerminalName
            SourceCsv = $file.FullName
            SchemaVersion = $identity.SchemaVersion
            LastWriteUtc = $file.LastWriteTimeUtc.ToString('o')
            Freshness = $freshness
            Eligibility = $eligibility
            ReasonCode = $identity.Status
        })
    }

    foreach($duplicateGroup in @($results | Where-Object Eligibility -eq 'Ready' | Group-Object AccountNumber | Where-Object Count -gt 1)) {
        foreach($duplicate in @($duplicateGroup.Group)) {
            $duplicate.Eligibility = 'Blocked'
            $duplicate.ReasonCode = 'DuplicateAccount'
        }
    }

    return @($results)
}

function Get-MoneyMachineSetupDiscovery {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$OneDriveCandidates,
        [string]$TerminalDataRoot
    )

    $useSignedInRoots = $null -eq $OneDriveCandidates
    if([string]::IsNullOrWhiteSpace($TerminalDataRoot)) {
        $TerminalDataRoot = Join-Path $env:APPDATA 'MetaQuotes\Terminal'
    }

    $roots = [System.Collections.Generic.List[object]]::new()
    if($useSignedInRoots) {
        foreach($root in @(Get-AmmarTradingWritableOneDriveRoots)) { $roots.Add($root) }
    } else {
        $seenRoots = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($candidate in @($OneDriveCandidates)) {
            if([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
            try { $resolved = Resolve-AmmarTradingLocalPath -Path ([string]$candidate) -PathType Container -Description 'OneDrive root' } catch { continue }
            if(-not $seenRoots.Add($resolved)) { continue }
            $roots.Add([pscustomobject]@{ Path=$resolved; Name=Split-Path -Leaf $resolved })
        }
    }

    $sources = [System.Collections.Generic.List[object]]::new()
    foreach($account in @(Get-AmmarTradingMt4Accounts -TerminalDataRoot $TerminalDataRoot)) {
        $sources.Add([pscustomobject]@{
            Path = $account.SourceCsv
            TerminalId = $account.TerminalId
            LastWriteUtc = $account.LastWriteUtc
        })
    }

    return [pscustomobject]@{
        OneDriveRoots = @($roots)
        Sources = @($sources | Sort-Object LastWriteUtc -Descending)
    }
}

function Test-MoneyMachineSetupRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$VpsName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedMT4Login,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceCsv,
        [Parameter(Mandatory)][AllowEmptyString()][string]$OneDriveRoot
    )

    $normalizedName = $VpsName.Trim()
    if([string]::IsNullOrWhiteSpace($normalizedName)) { throw 'VPS name is required.' }
    if($normalizedName.Length -gt 100) { throw 'VPS name must be 100 characters or fewer.' }

    $normalizedLogin = $ExpectedMT4Login.Trim()
    if($normalizedLogin -notmatch '^\d{4,20}$') { throw 'MT4 account number must contain 4 to 20 digits.' }

    $expandedSource = [Environment]::ExpandEnvironmentVariables($SourceCsv.Trim())
    if([IO.Path]::GetExtension($expandedSource) -ine '.csv') { throw 'Source file must use the .csv extension.' }
    $resolvedSource = Resolve-AmmarTradingLocalPath -Path $expandedSource -PathType Leaf -Description 'Source CSV'

    $resolvedOneDrive = Resolve-AmmarTradingOneDriveRoot -Path $OneDriveRoot -RequireWritable

    $schemaModule = Join-Path $PSScriptRoot 'MoneyMachineCsvSchemaV3.psm1'
    if(-not (Test-Path -LiteralPath $schemaModule -PathType Leaf)) { throw "Schema validator was not found: $schemaModule" }
    Import-Module -Name $schemaModule -Force -ErrorAction Stop
    $validation = Read-MoneyMachineBasketsCsv -Path $resolvedSource -ExpectedLogin $normalizedLogin

    return [pscustomobject]@{
        VpsName = $normalizedName
        ExpectedMT4Login = $normalizedLogin
        SourceCsv = $resolvedSource
        OneDriveRoot = $resolvedOneDrive
        RowCount = [int]$validation.RowCount
    }
}

function Save-AmmarTradingAccountBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][object[]]$Accounts
    )

    $fullConfigPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
    if(@($Accounts).Count -eq 0) { throw 'At least one account configuration is required.' }

    $selectedByLogin = @{}
    $selectedOrder = [System.Collections.Generic.List[string]]::new()
    foreach($account in @($Accounts)) {
        $newLogin = ([string]$account.ExpectedMT4Login).Trim()
        if($newLogin -notmatch '^\d{4,20}$') { throw 'Account configuration requires a valid MT4 account number.' }
        if($selectedByLogin.ContainsKey($newLogin)) { throw "Account configuration contains duplicate MT4 account '$newLogin'." }
        $selectedByLogin[$newLogin] = [pscustomobject][ordered]@{
            Enabled = 'true'
            VpsName = ([string]$account.VpsName).Trim()
            ExpectedMT4Login = $newLogin
            SourceCsv = [string]$account.SourceCsv
            OneDriveRoot = [string]$account.OneDriveRoot
        }
        $selectedOrder.Add($newLogin)
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $emitted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    if(Test-Path -LiteralPath $fullConfigPath -PathType Leaf) {
        foreach($existing in @(Import-Csv -LiteralPath $fullConfigPath -ErrorAction Stop)) {
            $existingLogin = ([string]$existing.ExpectedMT4Login).Trim()
            if($selectedByLogin.ContainsKey($existingLogin)) {
                if($emitted.Add($existingLogin)) { $rows.Add($selectedByLogin[$existingLogin]) }
            } else {
                $existingName = if($existing.PSObject.Properties['VpsName']) { [string]$existing.VpsName } else { '' }
                $rows.Add([pscustomobject][ordered]@{
                    Enabled = [string]$existing.Enabled
                    VpsName = $existingName
                    ExpectedMT4Login = $existingLogin
                    SourceCsv = [string]$existing.SourceCsv
                    OneDriveRoot = [string]$existing.OneDriveRoot
                })
            }
        }
    }
    foreach($newLogin in $selectedOrder) {
        if($emitted.Add($newLogin)) { $rows.Add($selectedByLogin[$newLogin]) }
    }

    $configDirectory = Split-Path -Parent $fullConfigPath
    if(-not (Test-Path -LiteralPath $configDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    }
    $lines = @($rows | ConvertTo-Csv -NoTypeInformation)
    $content = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
    $temporary = Join-Path $configDirectory ("accounts.$([guid]::NewGuid().ToString('N')).tmp")
    $backupPath = $null
    $configExisted = Test-Path -LiteralPath $fullConfigPath -PathType Leaf
    try {
        [IO.File]::WriteAllText($temporary, $content, (New-Object Text.UTF8Encoding($false)))
        if($configExisted) {
            $currentHash = (Get-FileHash -LiteralPath $fullConfigPath -Algorithm SHA256).Hash
            $nextHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
            if($currentHash -ceq $nextHash) {
                return [pscustomobject]@{ ConfigPath=$fullConfigPath; BackupPath=$null; Changed=$false; ConfigExisted=$true }
            }
            $backupPath = "$fullConfigPath.$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')).bak"
            [IO.File]::Replace($temporary, $fullConfigPath, $backupPath, $true)
        } else {
            [IO.File]::Move($temporary, $fullConfigPath)
        }
    } finally {
        if(Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }

    return [pscustomobject]@{ ConfigPath=$fullConfigPath; BackupPath=$backupPath; Changed=$true; ConfigExisted=$configExisted }
}

function Save-MoneyMachineAccountConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][psobject]$Account
    )

    return (Save-AmmarTradingAccountBatch -ConfigPath $ConfigPath -Accounts @($Account))
}

function Get-AmmarTradingSetupTransactionPaths {
    param([Parameter(Mandatory)][string]$RuntimeRoot)

    $stateDirectory = Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) 'state'
    return [pscustomobject]@{
        StateDirectory = $stateDirectory
        Marker = Join-Path $stateDirectory 'setup-transaction.json'
        Snapshot = Join-Path $stateDirectory 'setup-config.snapshot'
    }
}

function Flush-AmmarTradingFileToDisk {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Flush($true) } finally { $stream.Dispose() }
}

function Write-AmmarTradingAtomicUtf8 {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Content)

    $directory = Split-Path -Parent $Path
    if(-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $Content, (New-Object Text.UTF8Encoding($false)))
        Flush-AmmarTradingFileToDisk -Path $temporary
        if(Test-Path -LiteralPath $Path -PathType Leaf) {
            $backup = "$Path.$([guid]::NewGuid().ToString('N')).bak"
            try { [IO.File]::Replace($temporary, $Path, $backup, $true) }
            finally { if(Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue } }
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        if(Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Complete-AmmarTradingSetupTransaction {
    param([Parameter(Mandatory)][string]$RuntimeRoot)

    $paths = Get-AmmarTradingSetupTransactionPaths -RuntimeRoot $RuntimeRoot
    foreach($path in @($paths.Marker,$paths.Snapshot)) {
        if(Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
    }
}

function Restore-AmmarTradingSetupTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$ConfigPath
    )

    $paths = Get-AmmarTradingSetupTransactionPaths -RuntimeRoot $RuntimeRoot
    if(-not (Test-Path -LiteralPath $paths.Marker -PathType Leaf)) { return $false }
    $marker = Get-Content -LiteralPath $paths.Marker -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $expectedConfig = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
    if([int]$marker.Version -ne 1 -or [string]$marker.ConfigPath -cne $expectedConfig) {
        throw 'The setup recovery marker is invalid.'
    }

    $restoreTemporary = "$expectedConfig.$([guid]::NewGuid().ToString('N')).recovery.tmp"
    $replaceBackup = "$expectedConfig.$([guid]::NewGuid().ToString('N')).recovery.bak"
    try {
        if([bool]$marker.ConfigExisted) {
            if(-not (Test-Path -LiteralPath $paths.Snapshot -PathType Leaf)) { throw 'The setup recovery snapshot is missing.' }
            $configDirectory = Split-Path -Parent $expectedConfig
            if(-not (Test-Path -LiteralPath $configDirectory -PathType Container)) { New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null }
            [IO.File]::Copy($paths.Snapshot, $restoreTemporary, $false)
            Flush-AmmarTradingFileToDisk -Path $restoreTemporary
            if(Test-Path -LiteralPath $expectedConfig -PathType Leaf) {
                [IO.File]::Replace($restoreTemporary, $expectedConfig, $replaceBackup, $true)
            } else {
                [IO.File]::Move($restoreTemporary, $expectedConfig)
            }
        } elseif(Test-Path -LiteralPath $expectedConfig -PathType Leaf) {
            Remove-Item -LiteralPath $expectedConfig -Force -ErrorAction Stop
        }
        Complete-AmmarTradingSetupTransaction -RuntimeRoot $RuntimeRoot
        return $true
    } finally {
        if(Test-Path -LiteralPath $restoreTemporary) { Remove-Item -LiteralPath $restoreTemporary -Force -ErrorAction SilentlyContinue }
        if(Test-Path -LiteralPath $replaceBackup) { Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue }
    }
}

function Start-AmmarTradingSetupTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$ConfigPath
    )

    $fullConfigPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
    [void](Restore-AmmarTradingSetupTransaction -RuntimeRoot $RuntimeRoot -ConfigPath $fullConfigPath)
    $paths = Get-AmmarTradingSetupTransactionPaths -RuntimeRoot $RuntimeRoot
    if(-not (Test-Path -LiteralPath $paths.StateDirectory -PathType Container)) { New-Item -ItemType Directory -Path $paths.StateDirectory -Force | Out-Null }
    $configExisted = Test-Path -LiteralPath $fullConfigPath -PathType Leaf
    if($configExisted) {
        $snapshotTemporary = "$($paths.Snapshot).$([guid]::NewGuid().ToString('N')).tmp"
        $snapshotBackup = "$($paths.Snapshot).$([guid]::NewGuid().ToString('N')).bak"
        try {
            [IO.File]::Copy($fullConfigPath, $snapshotTemporary, $false)
            Flush-AmmarTradingFileToDisk -Path $snapshotTemporary
            if(Test-Path -LiteralPath $paths.Snapshot -PathType Leaf) {
                [IO.File]::Replace($snapshotTemporary, $paths.Snapshot, $snapshotBackup, $true)
            } else {
                [IO.File]::Move($snapshotTemporary, $paths.Snapshot)
            }
        } finally {
            if(Test-Path -LiteralPath $snapshotTemporary) { Remove-Item -LiteralPath $snapshotTemporary -Force -ErrorAction SilentlyContinue }
            if(Test-Path -LiteralPath $snapshotBackup) { Remove-Item -LiteralPath $snapshotBackup -Force -ErrorAction SilentlyContinue }
        }
    } elseif(Test-Path -LiteralPath $paths.Snapshot) {
        Remove-Item -LiteralPath $paths.Snapshot -Force -ErrorAction Stop
    }
    $marker = [ordered]@{ Version=1; ConfigPath=$fullConfigPath; ConfigExisted=$configExisted; State='Prepared' }
    Write-AmmarTradingAtomicUtf8 -Path $paths.Marker -Content ($marker | ConvertTo-Json -Depth 3 -Compress)
}

function Test-AmmarTradingReparsePoint {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$TrustedCloudFilesRoot = ''
    )

    $metadata = Get-AmmarTradingFileAttributeTagInfo -Path $Path
    if(($metadata.FileAttributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        return [uint32]$metadata.ReparseTag -ne 0
    }
    if(-not [string]::IsNullOrWhiteSpace($TrustedCloudFilesRoot) -and
       (Test-AmmarTradingPathBelow -Path $Path -Root $TrustedCloudFilesRoot) -and
       (([uint32]$metadata.ReparseTag -band [uint32]0x20000000) -eq 0) -and
       (Test-AmmarTradingCloudFilesReparseTag -Tag ([uint32]$metadata.ReparseTag)) ) {
        return $false
    }
    return $true
}

function Assert-AmmarTradingMigrationPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description,
        [string]$TrustedCloudFilesRoot = ''
    )

    if(Test-AmmarTradingReparsePoint -Path $Path -TrustedCloudFilesRoot $TrustedCloudFilesRoot) { throw "$Description contains a reparse point: $Path" }
}

function Copy-AmmarTradingLegacyData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OneDriveRoot,
        [Parameter(Mandatory)][string[]]$AccountNumbers
    )

    $resolvedRoot = Resolve-AmmarTradingOneDriveRoot -Path $OneDriveRoot -RequireWritable
    Assert-AmmarTradingMigrationPath -Path $resolvedRoot -Description 'OneDrive migration root' -TrustedCloudFilesRoot $resolvedRoot

    $accounts = [System.Collections.Generic.List[string]]::new()
    $seenAccounts = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($accountNumberValue in @($AccountNumbers)) {
        $accountNumber = ([string]$accountNumberValue).Trim()
        if($accountNumber -notmatch '^\d{4,20}$') { throw 'Legacy migration requires valid MT4 account numbers.' }
        if($seenAccounts.Add($accountNumber)) { $accounts.Add($accountNumber) }
    }

    $canonicalRoot = Join-Path $resolvedRoot 'AmmarTrading'
    if(Test-Path -LiteralPath $canonicalRoot) { Assert-AmmarTradingMigrationPath -Path $canonicalRoot -Description 'Canonical migration root' -TrustedCloudFilesRoot $resolvedRoot }

    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach($legacyName in @('Money Machine','AmarTrading')) {
        $legacyRoot = Join-Path $resolvedRoot $legacyName
        if(-not (Test-Path -LiteralPath $legacyRoot -PathType Container)) { continue }
        Assert-AmmarTradingMigrationPath -Path $legacyRoot -Description "Legacy '$legacyName' root" -TrustedCloudFilesRoot $resolvedRoot
        foreach($accountNumber in $accounts) {
            $sourceAccount = Join-Path $legacyRoot ("Account_{0}" -f $accountNumber)
            if(-not (Test-Path -LiteralPath $sourceAccount -PathType Container)) { continue }
            Assert-AmmarTradingMigrationPath -Path $sourceAccount -Description "Legacy account '$accountNumber' folder" -TrustedCloudFilesRoot $resolvedRoot
            $sourcePrefix = $sourceAccount.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            $items = @(Get-ChildItem -LiteralPath $sourceAccount -Recurse -Force -ErrorAction Stop)
            foreach($item in $items) {
                if(Test-AmmarTradingReparsePoint -Path $item.FullName -TrustedCloudFilesRoot $resolvedRoot) {
                    throw "Legacy account '$accountNumber' data contains a reparse point: $($item.FullName)"
                }
                if($item.PSIsContainer) { continue }
                if(-not $item.FullName.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Legacy migration candidate escaped account folder '$sourceAccount'."
                }
                $relativePath = $item.FullName.Substring($sourcePrefix.Length)
                if($relativePath -ieq 'SyncStatus.json') {
                    # This generated heartbeat is replaced after every local
                    # publication. It is not durable trading history and a
                    # stale legacy copy must not conflict with current status.
                    continue
                }
                $destination = Join-Path (Join-Path $canonicalRoot ("Account_{0}" -f $accountNumber)) $relativePath
                $candidates.Add([pscustomobject]@{ Source=$item.FullName; Destination=$destination })
            }
        }
    }

    $copied = 0
    $alreadyPresent = 0
    $conflict = 0
    foreach($candidate in $candidates) {
        $destinationDirectory = Split-Path -Parent $candidate.Destination
        $rootPrefix = $resolvedRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if(-not $destinationDirectory.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Legacy migration destination escaped OneDrive root '$resolvedRoot'."
        }

        $relativeDirectory = $destinationDirectory.Substring($rootPrefix.Length)
        $currentDirectory = $resolvedRoot
        foreach($part in @($relativeDirectory -split '[\\/]')) {
            if([string]::IsNullOrWhiteSpace($part)) { continue }
            $currentDirectory = Join-Path $currentDirectory $part
            [void](Invoke-AmmarTradingCanonicalPathOperation -CanonicalOneDriveRoot $resolvedRoot -Path @($currentDirectory) -Description 'Legacy migration destination' -Action {
                if(-not (Test-Path -LiteralPath $currentDirectory)) {
                    [void][IO.Directory]::CreateDirectory($currentDirectory)
                }
                Assert-AmmarTradingMigrationPath -Path $currentDirectory -Description 'Legacy migration destination' -TrustedCloudFilesRoot $resolvedRoot
            })
        }

        $sourceDetails = @(Invoke-AmmarTradingCanonicalPathOperation -CanonicalOneDriveRoot $resolvedRoot -Path @($candidate.Source) -Description 'Legacy migration source file' -Action {
            $sourceItem = Get-Item -LiteralPath $candidate.Source -Force -ErrorAction Stop
            [pscustomobject]@{
                Length = [int64]$sourceItem.Length
                Hash = (Get-FileHash -LiteralPath $candidate.Source -Algorithm SHA256).Hash
            }
        })[0]
        if(Test-Path -LiteralPath $candidate.Destination) {
            $destinationDetails = @(Invoke-AmmarTradingCanonicalPathOperation -CanonicalOneDriveRoot $resolvedRoot -Path @($candidate.Destination) -Description 'Legacy migration destination file' -Action {
                Assert-AmmarTradingMigrationPath -Path $candidate.Destination -Description 'Legacy migration destination file' -TrustedCloudFilesRoot $resolvedRoot
                $destinationItem = Get-Item -LiteralPath $candidate.Destination -Force -ErrorAction Stop
                [pscustomobject]@{
                    Length = [int64]$destinationItem.Length
                    Hash = (Get-FileHash -LiteralPath $candidate.Destination -Algorithm SHA256).Hash
                }
            })[0]
            if($sourceDetails.Length -eq $destinationDetails.Length -and $sourceDetails.Hash -ceq $destinationDetails.Hash) { $alreadyPresent++ } else { $conflict++ }
            continue
        }

        try {
            $migrationWriteState = [pscustomobject]@{ Source=[string]$candidate.Source }
            [void](Publish-AmmarTradingCanonicalTrustedFile -CanonicalOneDriveRoot $resolvedRoot -Destination $candidate.Destination -Description 'Legacy migration publication' -ExpectedLength $sourceDetails.Length -ExpectedSha256 $sourceDetails.Hash -AdditionalLockedPath @($candidate.Source) -WriteState $migrationWriteState -WriteAction {
                param($Stream,$State)
                $sourceStream = [IO.FileStream]::new([string]$State.Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                try { $sourceStream.CopyTo($Stream) }
                finally { $sourceStream.Dispose() }
            })
        } catch {
            $renameFailure = $_.Exception
            while($null -ne $renameFailure.InnerException) { $renameFailure = $renameFailure.InnerException }
            # OneDrive can materialize an existing cloud destination between
            # the absence check and the atomic rename. Cloud Files sometimes
            # reports that race as sharing violation (32), not only the normal
            # already-exists codes (80/183). Never overwrite in this path:
            # compare the now-visible destination bytes below and classify it
            # as already present or a conflict.
            if($renameFailure -isnot [ComponentModel.Win32Exception] -or $renameFailure.NativeErrorCode -notin @(32,80,183)) { throw }
            if(-not (Test-Path -LiteralPath $candidate.Destination -PathType Leaf)) { throw }
            $destinationDetails = @(Invoke-AmmarTradingCanonicalPathOperation -CanonicalOneDriveRoot $resolvedRoot -Path @($candidate.Destination) -Description 'Legacy migration destination file' -Action {
                $destinationItem = Get-Item -LiteralPath $candidate.Destination -Force -ErrorAction Stop
                [pscustomobject]@{
                    Length = [int64]$destinationItem.Length
                    Hash = (Get-FileHash -LiteralPath $candidate.Destination -Algorithm SHA256).Hash
                }
            })[0]
            if($sourceDetails.Length -eq $destinationDetails.Length -and $sourceDetails.Hash -ceq $destinationDetails.Hash) { $alreadyPresent++ } else { $conflict++ }
            continue
        }
        $destinationDetails = @(Invoke-AmmarTradingCanonicalPathOperation -CanonicalOneDriveRoot $resolvedRoot -Path @($candidate.Destination) -Description 'Legacy migration destination verification' -Action {
            $destinationItem = Get-Item -LiteralPath $candidate.Destination -Force -ErrorAction Stop
            [pscustomobject]@{
                Length = [int64]$destinationItem.Length
                Hash = (Get-FileHash -LiteralPath $candidate.Destination -Algorithm SHA256).Hash
            }
        })[0]
        if($destinationDetails.Length -ne $sourceDetails.Length -or $destinationDetails.Hash -cne $sourceDetails.Hash) { throw "Legacy migration destination verification failed for '$($candidate.Destination)'." }
        $copied++
    }

    return [pscustomobject][ordered]@{ Copied=$copied; AlreadyPresent=$alreadyPresent; Conflict=$conflict }
}

function Invoke-AmmarTradingBatchSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Request,
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$RuntimeRoot = $PSScriptRoot,
        [switch]$SkipTaskRegistration,
        [int]$StableCheckSeconds = 2,
        [int]$MutexWaitMilliseconds = 30000
    )

    $stages = [System.Collections.Generic.List[object]]::new()
    $vpsName = ([string]$Request.VpsName).Trim()
    if([string]::IsNullOrWhiteSpace($vpsName)) { throw 'VPS name is required.' }
    if($vpsName.Length -gt 100) { throw 'VPS name must be 100 characters or fewer.' }
    $oneDriveRoot = Resolve-AmmarTradingOneDriveRoot -Path ([string]$Request.OneDriveRoot) -RequireWritable
    $requestedAccounts = @($Request.Accounts)
    if($requestedAccounts.Count -eq 0) { throw 'At least one MT4 account must be selected.' }

    $schemaModule = Join-Path $PSScriptRoot 'MoneyMachineCsvSchemaV3.psm1'
    if(-not (Test-Path -LiteralPath $schemaModule -PathType Leaf)) { throw "Schema validator was not found: $schemaModule" }
    Import-Module -Name $schemaModule -Force -ErrorAction Stop

    $seenLogins = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $seenDiscoveries = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $seenSources = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $normalizedAccounts = [System.Collections.Generic.List[object]]::new()
    foreach($requested in $requestedAccounts) {
        $expectedLogin = ([string]$requested.ExpectedMT4Login).Trim()
        if($expectedLogin -notmatch '^\d{4,20}$') { throw 'MT4 account number must contain 4 to 20 digits.' }
        $discoveryId = ([string]$requested.DiscoveryId).Trim()
        if($discoveryId -cnotmatch '^[A-F0-9]{64}$') { throw "Account '$expectedLogin' requires a valid discovery identity." }
        if(-not $seenLogins.Add($expectedLogin)) { throw "The batch request contains duplicate MT4 account '$expectedLogin'." }
        if(-not $seenDiscoveries.Add($discoveryId)) { throw "The batch request contains duplicate discovery identity '$discoveryId'." }

        $sourceValue = [Environment]::ExpandEnvironmentVariables(([string]$requested.SourceCsv).Trim())
        if([IO.Path]::GetExtension($sourceValue) -ine '.csv') { throw 'Source file must use the .csv extension.' }
        $sourceCsv = Resolve-AmmarTradingLocalPath -Path $sourceValue -PathType Leaf -Description 'Source CSV'
        if(-not $seenSources.Add($sourceCsv)) { throw "The batch request contains duplicate source CSV '$sourceCsv'." }

        $validation = Read-MoneyMachineBasketsCsv -Path $sourceCsv -ExpectedLogin $expectedLogin
        $identity = Get-AmmarTradingCsvIdentity -Path $sourceCsv
        if($identity.Status -cne 'Ready' -or $identity.AccountNumber -cne $expectedLogin) { throw "Account '$expectedLogin' source is not a ready schema-v3 CSV." }
        $file = Get-Item -LiteralPath $sourceCsv -Force -ErrorAction Stop
        $fingerprint = '{0}|{1}|{2}|{3}' -f $file.FullName,$expectedLogin,$file.Length,$file.LastWriteTimeUtc.Ticks
        $currentDiscoveryId = Get-AmmarTradingDiscoveryHash -Fingerprint $fingerprint
        if($currentDiscoveryId -cne $discoveryId) { throw "Account '$expectedLogin' discovery identity is stale; refresh account discovery before setup." }

        $normalizedAccounts.Add([pscustomobject]@{
            VpsName = $vpsName
            ExpectedMT4Login = $expectedLogin
            SourceCsv = $file.FullName
            OneDriveRoot = $oneDriveRoot
            RowCount = [int]$validation.RowCount
            BrokerName = [string]$identity.BrokerName
            DiscoveryId = $discoveryId
        })
    }
    $stages.Add([pscustomobject]@{ Code='Validated'; Status='Success'; Message="Validated $($normalizedAccounts.Count) selected MT4 account source(s) before writing setup data." })

    $migration = Copy-AmmarTradingLegacyData -OneDriveRoot $oneDriveRoot -AccountNumbers @($normalizedAccounts | ForEach-Object ExpectedMT4Login)
    if($migration.Conflict -gt 0) { throw "Legacy data migration found $($migration.Conflict) conflicting destination file(s); no configuration was changed." }
    $stages.Add([pscustomobject]@{ Code='LegacyMigrated'; Status='Success'; Message="Legacy migration copied $($migration.Copied) file(s); $($migration.AlreadyPresent) were already present." })

    $fullConfigPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
    $transactionStarted = $false
    try {
        Start-AmmarTradingSetupTransaction -RuntimeRoot $RuntimeRoot -ConfigPath $fullConfigPath
        $transactionStarted = $true
        [void](Save-AmmarTradingAccountBatch -ConfigPath $fullConfigPath -Accounts @($normalizedAccounts))
        $stages.Add([pscustomobject]@{ Code='Configured'; Status='Success'; Message='Selected account configurations were saved in one atomic batch.' })

        $syncScript = Join-Path $PSScriptRoot 'Sync-BasketsToOneDrive.ps1'
        if(-not (Test-Path -LiteralPath $syncScript -PathType Leaf)) { throw "Sync script was not found: $syncScript" }
        $selectedLogins = @($normalizedAccounts | ForEach-Object ExpectedMT4Login)
        $syncResults = @(& {
            param($LibraryPath,$SyncConfigPath,$SyncAccounts,$SyncStableSeconds,$SyncMutexWaitMilliseconds,$SyncRuntimeRoot)
            . $LibraryPath -AsLibrary
            Invoke-MoneyMachineCsvSync -ConfigPath $SyncConfigPath -AccountNumbers $SyncAccounts -StableCheckSeconds $SyncStableSeconds -MaxRetries 1 -MutexWaitMilliseconds $SyncMutexWaitMilliseconds -RuntimeRoot $SyncRuntimeRoot
        } $syncScript $fullConfigPath $selectedLogins $StableCheckSeconds $MutexWaitMilliseconds $RuntimeRoot)
        $failed = @($syncResults | Where-Object Status -eq 'Error')
        if($failed.Count -gt 0) { throw (($failed | ForEach-Object { "Account $($_.AccountNumber): $($_.Message)" }) -join '; ') }
        foreach($account in $normalizedAccounts) {
            $expectedResult = @($syncResults | Where-Object AccountNumber -eq $account.ExpectedMT4Login | Select-Object -First 1)
            if($expectedResult.Count -ne 1 -or $expectedResult[0].Status -ne 'Success') { throw "Account '$($account.ExpectedMT4Login)' did not complete its first local publication." }
        }

        $stages.Add([pscustomobject]@{ Code='LocalPublished'; Status='Success'; Message="Published the first local CSV snapshot for $($normalizedAccounts.Count) selected account(s)." })

        if($SkipTaskRegistration) {
            $stages.Add([pscustomobject]@{ Code='TaskRegistrationSkipped'; Status='Success'; Message='Scheduled-task registration was skipped for staging acceptance.' })
            $taskState = 'RegistrationSkipped'
        } else {
            $installer = Join-Path $PSScriptRoot 'Install-BasketsSyncTask.ps1'
            if(-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw "Scheduled-task installer was not found: $installer" }
            & $script:AmmarTradingTaskInstallerInvoker $installer $fullConfigPath *> $null
            $stages.Add([pscustomobject]@{ Code='Automated'; Status='Success'; Message='Daily and logon catch-up synchronization tasks are active.' })
            $taskState = 'Registered'
        }

        $accountResults = [System.Collections.Generic.List[object]]::new()
        foreach($account in $normalizedAccounts) {
            $accountResults.Add([pscustomobject][ordered]@{
                AccountNumber = $account.ExpectedMT4Login
                BrokerName = $account.BrokerName
                Destination = Get-AmmarTradingDestinationPath -OneDriveRoot $account.OneDriveRoot -AccountNumber $account.ExpectedMT4Login
                LocalPublished = $true
                TaskState = $taskState
            })
        }
        Complete-AmmarTradingSetupTransaction -RuntimeRoot $RuntimeRoot
        $transactionStarted = $false
        return [pscustomobject]@{
            Status = 'Success'
            Accounts = @($accountResults)
            Stages = @($stages)
            CloudDeliveryVerified = $false
        }
    } catch {
        if($transactionStarted) {
            [void](Restore-AmmarTradingSetupTransaction -RuntimeRoot $RuntimeRoot -ConfigPath $fullConfigPath)
        }
        throw
    }
}

function Invoke-MoneyMachineSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Request,
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$RuntimeRoot = $PSScriptRoot,
        [switch]$SkipTaskRegistration,
        [int]$StableCheckSeconds = 2,
        [int]$MutexWaitMilliseconds = 30000
    )

    $normalized = Test-MoneyMachineSetupRequest -VpsName ([string]$Request.VpsName) -ExpectedMT4Login ([string]$Request.ExpectedMT4Login) -SourceCsv ([string]$Request.SourceCsv) -OneDriveRoot ([string]$Request.OneDriveRoot)
    $file = Get-Item -LiteralPath $normalized.SourceCsv -Force -ErrorAction Stop
    $fingerprint = '{0}|{1}|{2}|{3}' -f $file.FullName,$normalized.ExpectedMT4Login,$file.Length,$file.LastWriteTimeUtc.Ticks
    $batchRequest = [pscustomobject]@{
        VpsName = $normalized.VpsName
        OneDriveRoot = $normalized.OneDriveRoot
        Accounts = @([pscustomobject]@{
            DiscoveryId = Get-AmmarTradingDiscoveryHash -Fingerprint $fingerprint
            ExpectedMT4Login = $normalized.ExpectedMT4Login
            SourceCsv = $normalized.SourceCsv
        })
    }
    $batchResult = Invoke-AmmarTradingBatchSetup -Request $batchRequest -ConfigPath $ConfigPath -RuntimeRoot $RuntimeRoot -SkipTaskRegistration:$SkipTaskRegistration -StableCheckSeconds $StableCheckSeconds -MutexWaitMilliseconds $MutexWaitMilliseconds
    return [pscustomobject]@{
        Status = $batchResult.Status
        Account = $normalized
        Destination = $batchResult.Accounts[0].Destination
        CloudDeliveryVerified = $batchResult.CloudDeliveryVerified
        Stages = @($batchResult.Stages)
    }
}

Export-ModuleMember -Function Resolve-AmmarTradingLocalPath,Get-AmmarTradingWritableOneDriveRoots,Resolve-AmmarTradingOneDriveRoot,Assert-AmmarTradingTrustedDestinationPath,New-AmmarTradingTrustedDirectory,Invoke-AmmarTradingTrustedPathOperation,Move-AmmarTradingTrustedFileByHandle,Publish-AmmarTradingTrustedFile,Start-AmmarTradingSetupTransaction,Restore-AmmarTradingSetupTransaction,Get-AmmarTradingMt4Accounts,Get-MoneyMachineSetupDiscovery,Test-MoneyMachineSetupRequest,Save-MoneyMachineAccountConfig,Save-AmmarTradingAccountBatch,Copy-AmmarTradingLegacyData,Invoke-AmmarTradingBatchSetup,Invoke-MoneyMachineSetup
