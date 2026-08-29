#ifndef PublishDir
  #error PublishDir must be supplied by Build-AmmarTradingSync.ps1
#endif
#ifndef BootstrapperPath
  #error BootstrapperPath must be supplied by Build-AmmarTradingSync.ps1
#endif
#ifndef OutputDir
  #error OutputDir must be supplied by Build-AmmarTradingSync.ps1
#endif
#ifndef PayloadHashesPath
  #error PayloadHashesPath must be supplied by Build-AmmarTradingSync.ps1
#endif
#ifdef AcceptanceFaultInjection
  #ifndef FaultProbePath
    #error FaultProbePath must be supplied for the acceptance-only fault installer
  #endif
  #ifndef FaultManifestPath
    #error FaultManifestPath must be supplied for the acceptance-only fault installer
  #endif
#endif

#define ProductName "AmmarTrading Sync"
#define ProductVersion "1.0.0"
#define ProductPublisher "AmmarTrading"
#define ProductExe "AmmarTrading.Sync.exe"
#ifdef AcceptanceFaultInjection
  #define ProductOutputName "AmmarTrading Sync Upgrade Fault Test"
#else
  #define ProductOutputName "AmmarTrading Sync Setup"
#endif

[Setup]
AppId={{8F488698-AB96-45DB-A2BB-D9E868823F43}
AppName={#ProductName}
AppVersion={#ProductVersion}
AppPublisher={#ProductPublisher}
UninstallDisplayName={#ProductName}
VersionInfoCompany={#ProductPublisher}
VersionInfoDescription={#ProductName} Windows Installer
VersionInfoProductName={#ProductName}
VersionInfoProductVersion={#ProductVersion}
DefaultDirName={autopf}\AmmarTrading Sync
DefaultGroupName=AmmarTrading Sync
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename={#ProductOutputName}
Compression=lzma2/max
SolidCompression=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Uninstallable=yes
CloseApplications=yes
RestartApplications=no
SetupLogging=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#PayloadHashesPath}"; DestDir: "{tmp}"; DestName: "IncomingPayloadHashes.txt"; Flags: deleteafterinstall
#ifdef AcceptanceFaultInjection
Source: "{#FaultManifestPath}"; DestDir: "{tmp}"; DestName: "IncomingPayloadManifest.txt"; Flags: deleteafterinstall; AfterInstall: SnapshotProductPayload
#else
Source: "{#PublishDir}\AmmarTrading.Sync.payload-manifest.txt"; DestDir: "{tmp}"; DestName: "IncomingPayloadManifest.txt"; Flags: deleteafterinstall; AfterInstall: SnapshotProductPayload
#endif
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#BootstrapperPath}"; Flags: dontcopy noencryption
#ifdef AcceptanceFaultInjection
Source: "{#FaultManifestPath}"; DestDir: "{app}"; DestName: "AmmarTrading.Sync.payload-manifest.txt"; Flags: ignoreversion
Source: "{#FaultProbePath}"; DestDir: "{app}"; DestName: "{#ProductExe}"; Flags: ignoreversion
Source: "{#FaultProbePath}"; DestDir: "{app}"; DestName: "AmmarTrading.Sync.Core.dll"; Flags: ignoreversion
Source: "{#FaultProbePath}"; DestDir: "{app}\Assets\Web"; DestName: "index.html"; Flags: ignoreversion
Source: "{#FaultProbePath}"; DestDir: "{app}\Scripts"; DestName: "Sync-BasketsToOneDrive.ps1"; Flags: ignoreversion
Source: "{#FaultProbePath}"; DestDir: "{app}\Assets\Web"; DestName: "Task9IncomingOnly.bin"; Flags: ignoreversion; AfterInstall: HandleFaultProbeInstalled
Source: "{#FaultProbePath}"; DestDir: "{app}"; DestName: "Task9UpgradeFault.blocked"; Flags: ignoreversion; Check: ShouldInstallFaultCollision
#endif

[Icons]
Name: "{autoprograms}\AmmarTrading Sync"; Filename: "{app}\{#ProductExe}"; WorkingDir: "{app}"
Name: "{autodesktop}\AmmarTrading Sync"; Filename: "{app}\{#ProductExe}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#ProductExe}"; Description: "Launch AmmarTrading Sync"; Flags: nowait postinstall skipifsilent runasoriginaluser; Check: CanLaunchApplication

[Code]
const
  AMMAR_INVALID_FILE_ATTRIBUTES = $FFFFFFFF;
  AMMAR_MOVEFILE_REPLACE_EXISTING = 1;
  AMMAR_MOVEFILE_WRITE_THROUGH = 8;
  AMMAR_APP_ID = '{8F488698-AB96-45DB-A2BB-D9E868823F43}';
  AMMAR_STATE_MAGIC = 'AMMAR_TX_V2';
  AMMAR_MANIFEST_NAME = 'AmmarTrading.Sync.payload-manifest.txt';
  AMMAR_RECOVERY_BUILDING = '.ammar-installer-recovery.building';
  AMMAR_RECOVERY_ACTIVE = '.ammar-installer-recovery.active';
  AMMAR_RECOVERY_VERIFIED = '.ammar-installer-recovery.verified';
  AMMAR_TX_INVALID = 0;
  AMMAR_TX_PRIOR = 1;
  AMMAR_TX_INCOMING = 2;

var
  AppRoot: String;
  ActiveRecoveryRoot: String;
  SnapshotReady: Boolean;
  InstallationCompleted: Boolean;
  CommitFailed: Boolean;
  CommitFailureExitCode: Integer;
  RecoveryFailure: Boolean;

type
  TPayloadEntry = record
    Action: Char;
    RelativePath: String;
    SizeText: String;
    Hash: String;
  end;
  TPayloadEntries = array of TPayloadEntry;

function GetFileAttributesW(lpFileName: String): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall';

function MoveFileExW(lpExistingFileName, lpNewFileName: String; dwFlags: Cardinal): Boolean;
  external 'MoveFileExW@kernel32.dll stdcall';

function NormalizedPath(const Path: String): String;
begin
  Result := RemoveBackslashUnlessRoot(ExpandFileName(Path));
end;

function IsReparsePath(const Path: String): Boolean;
var
  Attributes: Cardinal;
begin
  Attributes := GetFileAttributesW(Path);
  Result := (Attributes <> AMMAR_INVALID_FILE_ATTRIBUTES) and
            ((Attributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0);
end;

function ValidateProtectedAppRoot: Boolean;
var
  ProgramFilesRoot, Cursor, Parent: String;
begin
  Result := False;
  AppRoot := NormalizedPath(ExpandConstant('{app}'));
  ProgramFilesRoot := NormalizedPath(ExpandConstant('{autopf}'));
  if (CompareText(AppRoot, ProgramFilesRoot) = 0) or
     (CompareText(Copy(AppRoot, 1, Length(ProgramFilesRoot) + 1), AddBackslash(ProgramFilesRoot)) <> 0) then
    exit;
  Cursor := AppRoot;
  while True do
  begin
    if (DirExists(Cursor) or FileExists(Cursor)) and IsReparsePath(Cursor) then
      exit;
    if CompareText(Cursor, ProgramFilesRoot) = 0 then
      break;
    Parent := ExtractFileDir(Cursor);
    if (Parent = '') or (CompareText(Parent, Cursor) = 0) then
      exit;
    Cursor := Parent;
  end;
  Result := True;
end;

function IsSafeRelativePayloadPath(const RelativePath: String): Boolean;
var
  Padded: String;
begin
  Padded := '\' + RelativePath + '\';
  Result := (RelativePath <> '') and
            (RelativePath[1] <> '\') and
            (RelativePath[Length(RelativePath)] <> '\') and
            (Pos('/', RelativePath) = 0) and
            (Pos(':', RelativePath) = 0) and
            (Pos('|', RelativePath) = 0) and
            (Pos('*', RelativePath) = 0) and
            (Pos('?', RelativePath) = 0) and
            (Pos('\\', RelativePath) = 0) and
            (Pos('\..\', Padded) = 0) and
            (Pos('\.\', Padded) = 0);
end;

function IsContainedNonReparsePayloadPath(const RelativePath: String): Boolean;
var
  Cursor, Parent: String;
  Attributes: Cardinal;
begin
  Result := False;
  if not IsSafeRelativePayloadPath(RelativePath) then
    exit;

  Cursor := AddBackslash(AppRoot) + RelativePath;
  if CompareText(Copy(Cursor, 1, Length(AppRoot) + 1), AddBackslash(AppRoot)) <> 0 then
    exit;

  while True do
  begin
    Attributes := GetFileAttributesW(Cursor);
    if (Attributes <> AMMAR_INVALID_FILE_ATTRIBUTES) and
       ((Attributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) then
      exit;
    if CompareText(Cursor, AppRoot) = 0 then
      break;
    Parent := ExtractFileDir(Cursor);
    if (Parent = '') or (CompareText(Parent, Cursor) = 0) then
      exit;
    Cursor := Parent;
  end;
  Result := True;
end;

function RecoveryChild(const RecoveryRoot, RelativePath: String): String;
begin
  Result := AddBackslash(RecoveryRoot) + RelativePath;
end;

function IsExactRecoveryRootSafe(const RecoveryRoot: String): Boolean;
var
  Name: String;
begin
  Name := ExtractFileName(RecoveryRoot);
  Result := ((Name = AMMAR_RECOVERY_BUILDING) or (Name = AMMAR_RECOVERY_ACTIVE) or
             (Name = AMMAR_RECOVERY_VERIFIED)) and
            (CompareText(ExtractFileDir(RecoveryRoot), AppRoot) = 0) and
            (not IsReparsePath(RecoveryRoot));
end;

function IsContainedNonReparseRecoveryPath(const RecoveryRoot, RelativePath: String): Boolean;
var
  BackupRoot, Cursor, Parent: String;
begin
  Result := False;
  if not IsSafeRelativePayloadPath(RelativePath) then exit;
  BackupRoot := RecoveryChild(RecoveryRoot, 'backup');
  Cursor := RecoveryChild(BackupRoot, RelativePath);
  while True do
  begin
    if (DirExists(Cursor) or FileExists(Cursor)) and IsReparsePath(Cursor) then exit;
    if CompareText(Cursor, BackupRoot) = 0 then break;
    Parent := ExtractFileDir(Cursor);
    if (Parent = '') or (CompareText(Parent, Cursor) = 0) then exit;
    Cursor := Parent;
  end;
  Result := True;
end;

procedure AtomicWriteLines(const Path: String; const Lines: TArrayOfString);
var
  TemporaryPath: String;
begin
  TemporaryPath := Path + '.new';
  DeleteFile(TemporaryPath);
  if not SaveStringsToFile(TemporaryPath, Lines, False) then
    RaiseException('Setup could not write durable recovery state.');
  if not MoveFileExW(TemporaryPath, Path,
    AMMAR_MOVEFILE_REPLACE_EXISTING or AMMAR_MOVEFILE_WRITE_THROUGH) then
    RaiseException('Setup could not atomically promote durable recovery state.');
end;

procedure AtomicWriteText(const Path, Value: String);
var
  Lines: TArrayOfString;
begin
  SetArrayLength(Lines, 1);
  Lines[0] := Value;
  AtomicWriteLines(Path, Lines);
end;

function LoadSingleLine(const Path: String; var Value: String): Boolean;
var Lines: TArrayOfString;
begin
  Result := LoadStringsFromFile(Path, Lines) and (GetArrayLength(Lines) = 1);
  if Result then Value := Lines[0];
end;

function TryGetFileSizeText(const Path: String; var SizeText: String): Boolean;
var Size: Int64;
begin
  Result := FileSize64(Path, Size);
  if Result then SizeText := IntToStr(Size);
end;

function RegistrationDigest(var Found: Boolean): String;
var
  Key, DisplayName, DisplayVersion, InstallLocation, UninstallString, QuietUninstallString: String;
  UninstallerPath, UninstallerDataPath, ExeSize, DataSize, QuietValue: String;
begin
  Key := 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{8F488698-AB96-45DB-A2BB-D9E868823F43}_is1';
  Found := RegQueryStringValue(HKEY_LOCAL_MACHINE, Key, 'DisplayName', DisplayName) and
           RegQueryStringValue(HKEY_LOCAL_MACHINE, Key, 'DisplayVersion', DisplayVersion) and
           RegQueryStringValue(HKEY_LOCAL_MACHINE, Key, 'InstallLocation', InstallLocation) and
           RegQueryStringValue(HKEY_LOCAL_MACHINE, Key, 'UninstallString', UninstallString);
  if not Found then begin if RegKeyExists(HKEY_LOCAL_MACHINE, Key) then Result := 'INVALID' else Result := 'NONE'; exit; end;
  if CompareText(NormalizedPath(InstallLocation), AppRoot) <> 0 then begin Result := 'INVALID'; exit; end;
  UninstallerPath := AddBackslash(AppRoot) + 'unins000.exe';
  UninstallerDataPath := AddBackslash(AppRoot) + 'unins000.dat';
  if (not FileExists(UninstallerPath)) or (not FileExists(UninstallerDataPath)) or
     IsReparsePath(UninstallerPath) or IsReparsePath(UninstallerDataPath) or
     (not TryGetFileSizeText(UninstallerPath, ExeSize)) or
     (not TryGetFileSizeText(UninstallerDataPath, DataSize)) then begin Result := 'INVALID'; exit; end;
  if RegQueryStringValue(HKEY_LOCAL_MACHINE, Key, 'QuietUninstallString', QuietUninstallString) then
    QuietValue := 'PRESENT|' + QuietUninstallString
  else QuietValue := 'MISSING';
  Result := GetSHA256OfUnicodeString(DisplayName + #10 + DisplayVersion + #10 +
    NormalizedPath(InstallLocation) + #10 + UninstallString + #10 + QuietValue + #10 +
    ExeSize + '|' + GetSHA256OfFile(UninstallerPath) + #10 +
    DataSize + '|' + GetSHA256OfFile(UninstallerDataPath));
end;

function ValidateCanonicalIncomingMetadata: Boolean;
var
  Key, DisplayName, DisplayVersion, InstallLocation, UninstallString: String;
  UninstallerPath, UninstallerDataPath: String;
begin
  Result := False;
  Key := 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{8F488698-AB96-45DB-A2BB-D9E868823F43}_is1';
  if not RegQueryStringValue(HKEY_LOCAL_MACHINE, Key, 'DisplayName', DisplayName) or
     not RegQueryStringValue(HKEY_LOCAL_MACHINE, Key, 'DisplayVersion', DisplayVersion) or
     not RegQueryStringValue(HKEY_LOCAL_MACHINE, Key, 'InstallLocation', InstallLocation) or
     not RegQueryStringValue(HKEY_LOCAL_MACHINE, Key, 'UninstallString', UninstallString) then exit;
  UninstallerPath := AddBackslash(AppRoot) + 'unins000.exe';
  UninstallerDataPath := AddBackslash(AppRoot) + 'unins000.dat';
  if (DisplayName <> '{#ProductName}') or (DisplayVersion <> '{#ProductVersion}') or
     (CompareText(NormalizedPath(InstallLocation), AppRoot) <> 0) or
     (Pos('"' + UninstallerPath + '"', UninstallString) <> 1) or
     (not FileExists(UninstallerPath)) or (not FileExists(UninstallerDataPath)) or
     IsReparsePath(UninstallerPath) or IsReparsePath(UninstallerDataPath) then exit;
  Result := True;
end;

procedure AddUniquePayloadPath(var Paths: TArrayOfString; const RelativePath: String);
var
  Index, NewLength: Integer;
begin
  if not IsSafeRelativePayloadPath(RelativePath) then
    RaiseException('The installed payload manifest contains an unsafe relative path.');
  for Index := 0 to GetArrayLength(Paths) - 1 do
    if CompareText(Paths[Index], RelativePath) = 0 then
      exit;
  NewLength := GetArrayLength(Paths);
  SetArrayLength(Paths, NewLength + 1);
  Paths[NewLength] := RelativePath;
end;

procedure AddManifestPayloadPaths(const ManifestPath: String; var Paths: TArrayOfString; Required: Boolean);
var
  Lines: TArrayOfString;
  Index: Integer;
begin
  if not FileExists(ManifestPath) then
  begin
    if Required then
      RaiseException('The incoming product payload manifest is missing.');
    exit;
  end;
  if not LoadStringsFromFile(ManifestPath, Lines) then
    RaiseException('Setup could not read a product payload manifest.');
  for Index := 0 to GetArrayLength(Lines) - 1 do
    AddUniquePayloadPath(Paths, Lines[Index]);
end;

function ContainsPayloadPath(const Paths: TArrayOfString; const RelativePath: String): Boolean;
var Index: Integer;
begin
  Result := False;
  for Index := 0 to GetArrayLength(Paths) - 1 do
    if CompareText(Paths[Index], RelativePath) = 0 then begin Result := True; exit; end;
end;

function CountFilesRecursive(const Root: String): Integer;
var
  FindRec: TFindRec;
begin
  Result := 0;
  if FindFirst(AddBackslash(Root) + '*', FindRec) then
  begin
    try
      repeat
        if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
        begin
          if (FindRec.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
            Result := Result + CountFilesRecursive(AddBackslash(Root) + FindRec.Name)
          else
            Result := Result + 1;
        end;
      until not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
end;

function TryParseState(const RecoveryRoot: String; var Entries: TPayloadEntries;
  var TransactionId, OldManifestHash, IncomingManifestHash, IncomingHashesHash, RegistrationHash: String): Boolean;
var
  Lines, OldPaths, IncomingPaths, UnionPaths, ParsedPaths: TArrayOfString;
  StatePath, StateHashPath, PhasePath, StateHash, ExpectedStateHash, EntryText: String;
  Index, EntryCount, ExistingCount, Separator1, Separator2, Separator3: Integer;
  Entry: TPayloadEntry;
  ActualSizeText: String;
begin
  Result := False;
  StatePath := RecoveryChild(RecoveryRoot, 'state.txt');
  StateHashPath := RecoveryChild(RecoveryRoot, 'state.sha256');
  PhasePath := RecoveryChild(RecoveryRoot, 'phase.txt');
  if (not FileExists(StatePath)) or (not FileExists(StateHashPath)) or (not FileExists(PhasePath)) then exit;
  if IsReparsePath(StatePath) or IsReparsePath(StateHashPath) or IsReparsePath(PhasePath) or
     IsReparsePath(RecoveryChild(RecoveryRoot, 'backup')) then exit;
  if not LoadStringsFromFile(StatePath, Lines) then exit;
  if GetArrayLength(Lines) < 9 then exit;
  if Lines[0] <> AMMAR_STATE_MAGIC then exit;
  if Lines[1] <> 'APPID|' + AMMAR_APP_ID then exit;
  if Lines[2] <> 'ROOT|' + AppRoot then exit;
  if Pos('TXID|', Lines[3]) <> 1 then exit;
  TransactionId := Copy(Lines[3], 6, Length(Lines[3]) - 5);
  if TransactionId = '' then exit;
  if Pos('OLDMANIFEST|', Lines[4]) <> 1 then exit;
  OldManifestHash := Copy(Lines[4], 13, Length(Lines[4]) - 12);
  if Pos('INCOMINGMANIFEST|', Lines[5]) <> 1 then exit;
  IncomingManifestHash := Copy(Lines[5], 18, Length(Lines[5]) - 17);
  if Pos('INCOMINGHASHES|', Lines[6]) <> 1 then exit;
  IncomingHashesHash := Copy(Lines[6], 16, Length(Lines[6]) - 15);
  if Pos('REGISTRATION|', Lines[7]) <> 1 then exit;
  RegistrationHash := Copy(Lines[7], 14, Length(Lines[7]) - 13);
  if Pos('COUNT|', Lines[8]) <> 1 then exit;
  EntryCount := StrToIntDef(Copy(Lines[8], 7, Length(Lines[8]) - 6), -1);
  if (EntryCount < 1) or (GetArrayLength(Lines) <> EntryCount + 9) then exit;
  if not LoadSingleLine(StateHashPath, ExpectedStateHash) then exit;
  StateHash := GetSHA256OfFile(StatePath);
  if CompareText(Trim(ExpectedStateHash), StateHash) <> 0 then exit;
  if not LoadSingleLine(PhasePath, EntryText) then exit;
  if (EntryText <> 'ACTIVE|' + TransactionId + '|' + StateHash) and
     (EntryText <> 'INCOMPLETE|' + TransactionId + '|' + StateHash) and
     (EntryText <> 'VERIFIED|' + TransactionId + '|' + StateHash) then exit;
  if (OldManifestHash <> 'NONE') and
     (IsReparsePath(RecoveryChild(RecoveryRoot, 'old-manifest.txt')) or
      (not FileExists(RecoveryChild(RecoveryRoot, 'old-manifest.txt'))) or
      (CompareText(GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'old-manifest.txt')), OldManifestHash) <> 0)) then exit;
  if IsReparsePath(RecoveryChild(RecoveryRoot, 'incoming-manifest.txt')) or
     (not FileExists(RecoveryChild(RecoveryRoot, 'incoming-manifest.txt'))) or
     (CompareText(GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'incoming-manifest.txt')), IncomingManifestHash) <> 0) then exit;
  if IsReparsePath(RecoveryChild(RecoveryRoot, 'incoming-hashes.txt')) or
     (not FileExists(RecoveryChild(RecoveryRoot, 'incoming-hashes.txt'))) or
     (CompareText(GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'incoming-hashes.txt')), IncomingHashesHash) <> 0) then exit;

  SetArrayLength(OldPaths, 0);
  SetArrayLength(IncomingPaths, 0);
  SetArrayLength(UnionPaths, 0);
  if OldManifestHash <> 'NONE' then
    AddManifestPayloadPaths(RecoveryChild(RecoveryRoot, 'old-manifest.txt'), OldPaths, True);
  AddManifestPayloadPaths(RecoveryChild(RecoveryRoot, 'incoming-manifest.txt'), IncomingPaths, True);
  for Index := 0 to GetArrayLength(OldPaths) - 1 do AddUniquePayloadPath(UnionPaths, OldPaths[Index]);
  for Index := 0 to GetArrayLength(IncomingPaths) - 1 do AddUniquePayloadPath(UnionPaths, IncomingPaths[Index]);
  if GetArrayLength(UnionPaths) <> EntryCount then exit;

  SetArrayLength(Entries, EntryCount);
  SetArrayLength(ParsedPaths, 0);
  ExistingCount := 0;
  for Index := 0 to EntryCount - 1 do
  begin
    EntryText := Lines[Index + 9];
    Separator1 := Pos('|', EntryText);
    if Separator1 <> 2 then exit;
    Entry.Action := EntryText[1];
    EntryText := Copy(EntryText, 3, Length(EntryText) - 2);
    Separator2 := Pos('|', EntryText);
    if Entry.Action = 'E' then
    begin
      if Separator2 < 2 then exit;
      Entry.RelativePath := Copy(EntryText, 1, Separator2 - 1);
      EntryText := Copy(EntryText, Separator2 + 1, Length(EntryText) - Separator2);
      Separator3 := Pos('|', EntryText);
      if Separator3 < 2 then exit;
      Entry.SizeText := Copy(EntryText, 1, Separator3 - 1);
      Entry.Hash := Copy(EntryText, Separator3 + 1, Length(EntryText) - Separator3);
      if (StrToInt64Def(Entry.SizeText, -1) < 0) or (Length(Entry.Hash) <> 64) then exit;
      if (not IsContainedNonReparsePayloadPath(Entry.RelativePath)) or
         (not IsContainedNonReparseRecoveryPath(RecoveryRoot, Entry.RelativePath)) or
         (not FileExists(RecoveryChild(RecoveryChild(RecoveryRoot, 'backup'), Entry.RelativePath))) or
         (not TryGetFileSizeText(RecoveryChild(RecoveryChild(RecoveryRoot, 'backup'), Entry.RelativePath), ActualSizeText)) or
         (ActualSizeText <> Entry.SizeText) or
         (CompareText(GetSHA256OfFile(RecoveryChild(RecoveryChild(RecoveryRoot, 'backup'), Entry.RelativePath)), Entry.Hash) <> 0) then exit;
      ExistingCount := ExistingCount + 1;
    end
    else if Entry.Action = 'M' then
    begin
      if Separator2 <> 0 then exit;
      Entry.RelativePath := EntryText;
      Entry.SizeText := '';
      Entry.Hash := '';
    end
    else exit;
    if (not IsSafeRelativePayloadPath(Entry.RelativePath)) or
       (not ContainsPayloadPath(UnionPaths, Entry.RelativePath)) then exit;
    if ContainsPayloadPath(ParsedPaths, Entry.RelativePath) then exit;
    AddUniquePayloadPath(ParsedPaths, Entry.RelativePath);
    Entries[Index] := Entry;
  end;
  if GetArrayLength(ParsedPaths) <> GetArrayLength(UnionPaths) then exit;
  if CountFilesRecursive(RecoveryChild(RecoveryRoot, 'backup')) <> ExistingCount then exit;
  Result := True;
end;

function VerifyIncomingCommittedPayload(const RecoveryRoot, IncomingManifestHash,
  IncomingHashesHash: String): Boolean;
var
  ManifestPaths, HashLines, SeenPaths: TArrayOfString;
  Index, Separator1, Separator2: Integer;
  Line, RelativePath, SizeText, ExpectedHash, ActualSizeText, InstalledPath: String;
begin
  Result := False;
  if CompareText(GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'incoming-manifest.txt')), IncomingManifestHash) <> 0 then exit;
  if CompareText(GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'incoming-hashes.txt')), IncomingHashesHash) <> 0 then exit;
  if (not FileExists(AddBackslash(AppRoot) + AMMAR_MANIFEST_NAME)) or
     (CompareText(GetSHA256OfFile(AddBackslash(AppRoot) + AMMAR_MANIFEST_NAME), IncomingManifestHash) <> 0) then exit;
  SetArrayLength(ManifestPaths, 0);
  SetArrayLength(SeenPaths, 0);
  AddManifestPayloadPaths(RecoveryChild(RecoveryRoot, 'incoming-manifest.txt'), ManifestPaths, True);
  if not LoadStringsFromFile(RecoveryChild(RecoveryRoot, 'incoming-hashes.txt'), HashLines) then exit;
  if GetArrayLength(HashLines) <> GetArrayLength(ManifestPaths) then exit;
  for Index := 0 to GetArrayLength(HashLines) - 1 do
  begin
    Line := HashLines[Index];
    Separator1 := Pos('|', Line);
    if Separator1 < 2 then exit;
    RelativePath := Copy(Line, 1, Separator1 - 1);
    Line := Copy(Line, Separator1 + 1, Length(Line) - Separator1);
    Separator2 := Pos('|', Line);
    if Separator2 < 2 then exit;
    SizeText := Copy(Line, 1, Separator2 - 1);
    ExpectedHash := Copy(Line, Separator2 + 1, Length(Line) - Separator2);
    if (StrToInt64Def(SizeText, -1) < 0) or (Length(ExpectedHash) <> 64) or
       (not ContainsPayloadPath(ManifestPaths, RelativePath)) or
       ContainsPayloadPath(SeenPaths, RelativePath) or
       (not IsContainedNonReparsePayloadPath(RelativePath)) then exit;
    InstalledPath := AddBackslash(AppRoot) + RelativePath;
    if (not FileExists(InstalledPath)) or (not TryGetFileSizeText(InstalledPath, ActualSizeText)) or
       (ActualSizeText <> SizeText) or
       (CompareText(GetSHA256OfFile(InstalledPath), ExpectedHash) <> 0) then exit;
    AddUniquePayloadPath(SeenPaths, RelativePath);
  end;
  Result := GetArrayLength(SeenPaths) = GetArrayLength(ManifestPaths);
end;

function ClassifyActiveTransaction(const RecoveryRoot: String): Integer;
var
  Entries: TPayloadEntries;
  TransactionId, OldManifestHash, IncomingManifestHash, IncomingHashesHash, RegistrationHash: String;
  CurrentRegistrationHash: String;
  RegistrationFound: Boolean;
begin
  Result := AMMAR_TX_INVALID;
  if (not IsExactRecoveryRootSafe(RecoveryRoot)) or
     (not TryParseState(RecoveryRoot, Entries, TransactionId, OldManifestHash,
       IncomingManifestHash, IncomingHashesHash, RegistrationHash)) then exit;
  CurrentRegistrationHash := RegistrationDigest(RegistrationFound);
  if CompareText(CurrentRegistrationHash, RegistrationHash) = 0 then begin Result := AMMAR_TX_PRIOR; exit; end;
  if ValidateCanonicalIncomingMetadata and
     VerifyIncomingCommittedPayload(RecoveryRoot, IncomingManifestHash, IncomingHashesHash) then
    Result := AMMAR_TX_INCOMING;
end;

procedure SetRecoveryPhase(const RecoveryRoot, Phase, TransactionId, StateHash: String);
begin
  AtomicWriteText(RecoveryChild(RecoveryRoot, 'phase.txt'), Phase + '|' + TransactionId + '|' + StateHash);
end;

function VerifyRestoredPayload(const Entries: TPayloadEntries; const OldManifestHash, RegistrationHash: String): Boolean;
var
  Index: Integer;
  InstalledPath, CurrentRegistrationHash, ActualSizeText: String;
  RegistrationFound: Boolean;
begin
  Result := False;
  for Index := 0 to GetArrayLength(Entries) - 1 do
  begin
    InstalledPath := AddBackslash(AppRoot) + Entries[Index].RelativePath;
    if Entries[Index].Action = 'E' then
    begin
      if (not FileExists(InstalledPath)) or
         (not TryGetFileSizeText(InstalledPath, ActualSizeText)) or
         (ActualSizeText <> Entries[Index].SizeText) or
         (CompareText(GetSHA256OfFile(InstalledPath), Entries[Index].Hash) <> 0) then exit;
    end
    else if FileExists(InstalledPath) or DirExists(InstalledPath) then exit;
  end;
  if OldManifestHash = 'NONE' then
  begin
    if FileExists(AddBackslash(AppRoot) + AMMAR_MANIFEST_NAME) then exit;
  end
  else if (not FileExists(AddBackslash(AppRoot) + AMMAR_MANIFEST_NAME)) or
          (CompareText(GetSHA256OfFile(AddBackslash(AppRoot) + AMMAR_MANIFEST_NAME), OldManifestHash) <> 0) then exit;
  CurrentRegistrationHash := RegistrationDigest(RegistrationFound);
  if CompareText(CurrentRegistrationHash, RegistrationHash) <> 0 then exit;
  Result := True;
end;

function RestoreActiveTransaction(const RecoveryRoot: String): Boolean;
var
  Entries: TPayloadEntries;
  TransactionId, OldManifestHash, IncomingManifestHash, IncomingHashesHash, RegistrationHash: String;
  InstalledPath, BackupPath, StateHash: String;
  Index: Integer;
begin
  Result := False;
  if (not IsExactRecoveryRootSafe(RecoveryRoot)) or
     (ClassifyActiveTransaction(RecoveryRoot) <> AMMAR_TX_PRIOR) or
     (not TryParseState(RecoveryRoot, Entries, TransactionId, OldManifestHash,
       IncomingManifestHash, IncomingHashesHash, RegistrationHash)) then
  begin
    Log('ERROR: Durable recovery transaction is invalid; payload was not touched.');
    exit;
  end;
  StateHash := GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'state.txt'));
  for Index := 0 to GetArrayLength(Entries) - 1 do
  begin
    InstalledPath := AddBackslash(AppRoot) + Entries[Index].RelativePath;
    if not IsContainedNonReparsePayloadPath(Entries[Index].RelativePath) then exit;
#ifdef AcceptanceFaultInjection
    if (ExpandConstant('{param:TASK9MODE|}') = 'restorefail') and (Index = 1) then
    begin
      SetRecoveryPhase(RecoveryRoot, 'INCOMPLETE', TransactionId, StateHash);
      Log('ERROR: Task 9 injected restore failure.');
      exit;
    end;
#endif
    if Entries[Index].Action = 'E' then
    begin
      BackupPath := RecoveryChild(RecoveryChild(RecoveryRoot, 'backup'), Entries[Index].RelativePath);
      if FileExists(InstalledPath) and (not DeleteFile(InstalledPath)) then exit;
      if not ForceDirectories(ExtractFileDir(InstalledPath)) then exit;
      if not CopyFile(BackupPath, InstalledPath, False) then exit;
    end
    else
    begin
      if DirExists(InstalledPath) then exit;
      if FileExists(InstalledPath) and (not DeleteFile(InstalledPath)) then exit;
    end;
  end;
  if not VerifyRestoredPayload(Entries, OldManifestHash, RegistrationHash) then
  begin
    SetRecoveryPhase(RecoveryRoot, 'INCOMPLETE', TransactionId, StateHash);
    exit;
  end;
  SetRecoveryPhase(RecoveryRoot, 'VERIFIED', TransactionId, StateHash);
  Result := True;
end;

function CleanupVerifiedRecovery(const RecoveryRoot: String): Boolean; forward;

function FinalizeIncomingTransaction(const RecoveryRoot: String): Boolean;
var
  Entries: TPayloadEntries;
  TransactionId, OldManifestHash, IncomingManifestHash, IncomingHashesHash, RegistrationHash: String;
  StateHash, VerifiedRoot: String;
begin
  Result := False;
  if ClassifyActiveTransaction(RecoveryRoot) <> AMMAR_TX_INCOMING then exit;
  if not TryParseState(RecoveryRoot, Entries, TransactionId, OldManifestHash,
    IncomingManifestHash, IncomingHashesHash, RegistrationHash) then exit;
  StateHash := GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'state.txt'));
  SetRecoveryPhase(RecoveryRoot, 'VERIFIED', TransactionId, StateHash);
  VerifiedRoot := AddBackslash(AppRoot) + AMMAR_RECOVERY_VERIFIED;
  if not RenameFile(RecoveryRoot, VerifiedRoot) then exit;
  Result := CleanupVerifiedRecovery(VerifiedRoot);
end;

function ResolveActiveTransaction(const RecoveryRoot: String): Boolean;
var Classification: Integer;
    VerifiedRoot: String;
begin
  Result := False;
  Classification := ClassifyActiveTransaction(RecoveryRoot);
  if Classification = AMMAR_TX_INCOMING then begin Result := FinalizeIncomingTransaction(RecoveryRoot); exit; end;
  if Classification <> AMMAR_TX_PRIOR then exit;
  if not RestoreActiveTransaction(RecoveryRoot) then exit;
  VerifiedRoot := AddBackslash(AppRoot) + AMMAR_RECOVERY_VERIFIED;
  if not RenameFile(RecoveryRoot, VerifiedRoot) then exit;
  Result := CleanupVerifiedRecovery(VerifiedRoot);
end;

function CleanupVerifiedRecovery(const RecoveryRoot: String): Boolean;
begin
  Result := False;
  if not IsExactRecoveryRootSafe(RecoveryRoot) then exit;
  if not DelTree(RecoveryRoot, True, True, True) then exit;
  Result := not DirExists(RecoveryRoot);
end;

function RecoverBeforeInstall: String;
var
  BuildingRoot, VerifiedRoot: String;
begin
  Result := '';
  BuildingRoot := AddBackslash(AppRoot) + AMMAR_RECOVERY_BUILDING;
  ActiveRecoveryRoot := AddBackslash(AppRoot) + AMMAR_RECOVERY_ACTIVE;
  VerifiedRoot := AddBackslash(AppRoot) + AMMAR_RECOVERY_VERIFIED;
  if DirExists(BuildingRoot) then
  begin
    Result := 'An incomplete recovery snapshot requires support; installation was not changed.';
    exit;
  end;
  if DirExists(VerifiedRoot) then
  begin
    if not CleanupVerifiedRecovery(VerifiedRoot) then
      Result := 'A verified recovery transaction could not be cleaned; installation was not changed.';
    exit;
  end;
  if DirExists(ActiveRecoveryRoot) then
  begin
    if not ResolveActiveTransaction(ActiveRecoveryRoot) then
    begin
      RecoveryFailure := True;
      Result := 'A previous installation could not be recovered safely. Product files were not overwritten.';
      exit;
    end;
    if DirExists(ActiveRecoveryRoot) or DirExists(VerifiedRoot) then
      Result := 'Recovery completed but cleanup is pending; run setup again.';
  end;
end;

procedure SnapshotProductPayload;
var
  PayloadPaths, StateLines: TArrayOfString;
  Index, TransactionRandom: Integer;
  RelativePath, InstalledPath, BackupPath, BuildingRoot, OldManifestPath: String;
  TransactionId, OldManifestHash, IncomingManifestHash, IncomingHashesHash, RegistrationHash, StateHash, BackupSizeText: String;
  RegistrationFound: Boolean;
begin
  SetArrayLength(PayloadPaths, 0);
  AddManifestPayloadPaths(ExpandConstant('{app}\AmmarTrading.Sync.payload-manifest.txt'), PayloadPaths, False);
  AddManifestPayloadPaths(ExpandConstant('{tmp}\IncomingPayloadManifest.txt'), PayloadPaths, True);
  if GetArrayLength(PayloadPaths) = 0 then
    RaiseException('The product payload manifest is empty.');

  BuildingRoot := AddBackslash(AppRoot) + AMMAR_RECOVERY_BUILDING;
  ActiveRecoveryRoot := AddBackslash(AppRoot) + AMMAR_RECOVERY_ACTIVE;
  if DirExists(BuildingRoot) or DirExists(ActiveRecoveryRoot) then
    RaiseException('A durable recovery transaction already exists.');
  if not ForceDirectories(RecoveryChild(BuildingRoot, 'backup')) then
    RaiseException('Setup could not create durable recovery storage.');
  if IsReparsePath(BuildingRoot) then
    RaiseException('Setup refused a reparse-point recovery directory.');
  OldManifestPath := AddBackslash(AppRoot) + AMMAR_MANIFEST_NAME;
  if FileExists(OldManifestPath) then
  begin
    if not CopyFile(OldManifestPath, RecoveryChild(BuildingRoot, 'old-manifest.txt'), False) then
      RaiseException('Setup could not preserve the installed payload manifest.');
    OldManifestHash := GetSHA256OfFile(RecoveryChild(BuildingRoot, 'old-manifest.txt'));
  end
  else OldManifestHash := 'NONE';
  if not CopyFile(ExpandConstant('{tmp}\IncomingPayloadManifest.txt'), RecoveryChild(BuildingRoot, 'incoming-manifest.txt'), False) then
    RaiseException('Setup could not preserve the incoming payload manifest.');
  IncomingManifestHash := GetSHA256OfFile(RecoveryChild(BuildingRoot, 'incoming-manifest.txt'));
  if not CopyFile(ExpandConstant('{tmp}\IncomingPayloadHashes.txt'), RecoveryChild(BuildingRoot, 'incoming-hashes.txt'), False) then
    RaiseException('Setup could not preserve incoming payload hashes.');
  IncomingHashesHash := GetSHA256OfFile(RecoveryChild(BuildingRoot, 'incoming-hashes.txt'));
  Log('Durable snapshot: incoming manifest preserved.');
  RegistrationHash := RegistrationDigest(RegistrationFound);
  Log('Durable snapshot: registration bound.');
  TransactionRandom := Random(1000000000);
  Log('Durable snapshot: random suffix created.');
  TransactionId := IntToStr(TransactionRandom);
  TransactionRandom := Random(1000000000);
  TransactionId := TransactionId + '-' + IntToStr(TransactionRandom);
  Log('Durable snapshot: transaction identifier created.');
  SetArrayLength(StateLines, GetArrayLength(PayloadPaths) + 9);
  Log('Durable snapshot: state allocated.');
  StateLines[0] := AMMAR_STATE_MAGIC;
  StateLines[1] := 'APPID|' + AMMAR_APP_ID;
  StateLines[2] := 'ROOT|' + AppRoot;
  StateLines[3] := 'TXID|' + TransactionId;
  StateLines[4] := 'OLDMANIFEST|' + OldManifestHash;
  StateLines[5] := 'INCOMINGMANIFEST|' + IncomingManifestHash;
  StateLines[6] := 'INCOMINGHASHES|' + IncomingHashesHash;
  StateLines[7] := 'REGISTRATION|' + RegistrationHash;
  StateLines[8] := 'COUNT|' + IntToStr(GetArrayLength(PayloadPaths));
  for Index := 0 to GetArrayLength(PayloadPaths) - 1 do
  begin
    RelativePath := PayloadPaths[Index];
    if not IsContainedNonReparsePayloadPath(RelativePath) then
      RaiseException('Setup refused a payload path outside the application directory or through a reparse point.');
    InstalledPath := AddBackslash(ExpandConstant('{app}')) + RelativePath;
    if DirExists(InstalledPath) then
      RaiseException('Setup refused a payload file path occupied by a directory.');
    if FileExists(InstalledPath) then
    begin
      BackupPath := RecoveryChild(RecoveryChild(BuildingRoot, 'backup'), RelativePath);
      if not ForceDirectories(ExtractFileDir(BackupPath)) then
        RaiseException('Setup could not create the product rollback directory.');
      if not CopyFile(InstalledPath, BackupPath, False) then
        RaiseException('Setup could not snapshot the existing product payload. The installation was not changed.');
      if not TryGetFileSizeText(BackupPath, BackupSizeText) then
        RaiseException('Setup could not measure the durable payload backup.');
      StateLines[Index + 9] := 'E|' + RelativePath + '|' + BackupSizeText + '|' + GetSHA256OfFile(BackupPath);
    end
    else
      StateLines[Index + 9] := 'M|' + RelativePath;
  end;
  AtomicWriteLines(RecoveryChild(BuildingRoot, 'state.txt'), StateLines);
  StateHash := GetSHA256OfFile(RecoveryChild(BuildingRoot, 'state.txt'));
  AtomicWriteText(RecoveryChild(BuildingRoot, 'state.sha256'), StateHash);
  AtomicWriteText(RecoveryChild(BuildingRoot, 'phase.txt'), 'ACTIVE|' + TransactionId + '|' + StateHash);
  if not RenameFile(BuildingRoot, ActiveRecoveryRoot) then
    RaiseException('Setup could not atomically activate durable recovery state.');
  SnapshotReady := True;
end;

function IsWebView2Installed: Boolean; forward;

function InstallWebViewPrerequisite(var NeedsRestart: Boolean): String;
var ResultCode: Integer;
begin
  Result := '';
#ifdef AcceptanceFaultInjection
  if ExpandConstant('{param:TASK9MODE|}') = 'webviewfail' then
  begin
    CommitFailureExitCode := 71;
    Result := 'Task 9 injected WebView2 prerequisite failure before product mutation.';
    exit;
  end;
#endif
  if IsWebView2Installed then exit;
  ExtractTemporaryFile('MicrosoftEdgeWebView2Setup.exe');
  if not Exec(ExpandConstant('{tmp}\MicrosoftEdgeWebView2Setup.exe'), '/silent /install', '',
    SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    CommitFailureExitCode := 72;
    Result := 'Microsoft Edge WebView2 Runtime could not be launched.';
    exit;
  end;
  if ResultCode = 3010 then
  begin
    NeedsRestart := True;
    CommitFailureExitCode := 73;
    Result := 'Microsoft Edge WebView2 Runtime requires a restart before AmmarTrading Sync can be installed.';
    exit;
  end;
  if (ResultCode <> 0) or (not IsWebView2Installed) then
  begin
    CommitFailureExitCode := 74;
    Result := 'Microsoft Edge WebView2 Runtime installation did not complete successfully.';
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  InstallationCompleted := False;
  CommitFailed := False;
  CommitFailureExitCode := 0;
  SnapshotReady := False;
  RecoveryFailure := False;
  if not ValidateProtectedAppRoot then
  begin
    Result := 'AmmarTrading Sync must be installed beneath the machine Program Files directory without reparse points.';
    exit;
  end;
  Result := InstallWebViewPrerequisite(NeedsRestart);
  if Result <> '' then exit;
  Result := RecoverBeforeInstall;
#ifdef AcceptanceFaultInjection
  if (Result = '') and (ExpandConstant('{param:TASK9MODE|}') = 'recoveryonly') then
    Result := 'Task 9 recovery-only test stopped before payload mutation.';
#endif
end;

procedure CurStepChanged(CurStep: TSetupStep);
#ifdef AcceptanceFaultInjection
var Index: Integer;
#endif
begin
  if CurStep = ssPostInstall then
  begin
    if SnapshotReady and DirExists(ActiveRecoveryRoot) then
    begin
#ifdef AcceptanceFaultInjection
      if ExpandConstant('{param:TASK9MODE|}') = 'incomingcompletecrash' then
      begin
        AtomicWriteText(RecoveryChild(ActiveRecoveryRoot, 'incoming-complete-ready'), 'ready');
        for Index := 1 to 720 do Sleep(250);
      end;
#endif
      if not FinalizeIncomingTransaction(ActiveRecoveryRoot) then
      begin
        CommitFailed := True;
        CommitFailureExitCode := 75;
        RaiseException('The installed payload could not be committed safely; durable recovery was retained.');
      end;
    end;
    InstallationCompleted := True;
  end;
end;

function GetCustomSetupExitCode: Integer;
begin
  Result := CommitFailureExitCode;
end;

function CanLaunchApplication: Boolean;
begin
  Result := not CommitFailed;
end;

procedure DeinitializeSetup;
begin
  if InstallationCompleted or (not SnapshotReady) or RecoveryFailure then
    exit;
  if not ResolveActiveTransaction(ActiveRecoveryRoot) then
  begin
    RecoveryFailure := True;
    Log('ERROR: Durable recovery remains; setup did not guess between prior and incoming payload state.');
  end;
end;

#ifdef AcceptanceFaultInjection
procedure HandleFaultProbeInstalled;
var
  MarkerPath: String;
  Index: Integer;
begin
  if ExpandConstant('{param:TASK9MODE|}') <> 'crash' then exit;
  MarkerPath := RecoveryChild(ActiveRecoveryRoot, 'crash-ready');
  AtomicWriteText(MarkerPath, 'ready');
  for Index := 1 to 720 do Sleep(250);
end;
#endif

function ShouldInstallFaultCollision: Boolean;
begin
#ifdef AcceptanceFaultInjection
  Result := ExpandConstant('{param:TASK9MODE|}') <> 'incomingcompletecrash';
#else
  Result := False;
#endif
end;

function HasWebView2Version(const RootKey: Integer): Boolean;
var
  Version: String;
begin
  Result := RegQueryStringValue(
    RootKey,
    'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
    'pv',
    Version) and (Version <> '') and (Version <> '0.0.0.0');
end;

function IsWebView2Installed: Boolean;
begin
  Result := HasWebView2Version(HKEY_LOCAL_MACHINE_32) or
            HasWebView2Version(HKEY_CURRENT_USER_32);
end;

function InitializeUninstall: Boolean;
var BuildingRoot, VerifiedRoot: String;
begin
  Result := False;
  if not ValidateProtectedAppRoot then exit;
  BuildingRoot := AddBackslash(AppRoot) + AMMAR_RECOVERY_BUILDING;
  ActiveRecoveryRoot := AddBackslash(AppRoot) + AMMAR_RECOVERY_ACTIVE;
  VerifiedRoot := AddBackslash(AppRoot) + AMMAR_RECOVERY_VERIFIED;
  if DirExists(BuildingRoot) then
  begin
    Log('ERROR: Uninstall blocked by an incomplete durable snapshot.');
    exit;
  end;
  if DirExists(VerifiedRoot) and (not CleanupVerifiedRecovery(VerifiedRoot)) then exit;
  if DirExists(ActiveRecoveryRoot) and (not ResolveActiveTransaction(ActiveRecoveryRoot)) then
  begin
    Log('ERROR: Uninstall blocked by invalid durable recovery state; payload and registration were preserved.');
    exit;
  end;
  Result := True;
end;
