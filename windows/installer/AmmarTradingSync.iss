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
  #ifndef FaultProductVersion
    #error FaultProductVersion must be supplied for the acceptance-only fault installer
  #endif
#endif

#define ProductName "AmmarTrading Sync"
#ifdef AcceptanceFaultInjection
  #define ProductVersion FaultProductVersion
#else
  #define ProductVersion "1.0.0"
#endif
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
Source: "{#PayloadHashesPath}"; DestName: "IncomingPayloadHashes.txt"; Flags: dontcopy noencryption
#ifdef AcceptanceFaultInjection
Source: "{#FaultManifestPath}"; DestName: "IncomingPayloadManifest.txt"; Flags: dontcopy noencryption
#else
Source: "{#PublishDir}\AmmarTrading.Sync.payload-manifest.txt"; DestName: "IncomingPayloadManifest.txt"; Flags: dontcopy noencryption
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

[Code]
const
  AMMAR_INVALID_FILE_ATTRIBUTES = $FFFFFFFF;
  AMMAR_MOVEFILE_REPLACE_EXISTING = 1;
  AMMAR_MOVEFILE_WRITE_THROUGH = 8;
  AMMAR_APP_ID = '{8F488698-AB96-45DB-A2BB-D9E868823F43}';
  AMMAR_STATE_MAGIC = 'AMMAR_TX_V3';
  AMMAR_COMMIT_MAGIC = 'AMMAR_COMMIT_V1';
  AMMAR_UNINS_PROOF_MAGIC = 'AMMAR_PRIOR_UNINS_PROOF_V1';
  AMMAR_INCOMING_UNINS_PROOF_MAGIC = 'AMMAR_INCOMING_UNINS_PROOF_V1';
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
  InsideUninstaller: Boolean;
  UninstallUsesPriorProof: Boolean;
  LaunchAfterCommitCheckbox: TNewCheckBox;

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

function CurrentUninstallerMeta(const FileName: String; var Meta: String): Boolean; forward;

function IsSHA256Digest(const Value: String): Boolean;
var
  Index: Integer;
begin
  Result := False;
  if Length(Value) <> 64 then exit;
  for Index := 1 to Length(Value) do
    if not (((Value[Index] >= '0') and (Value[Index] <= '9')) or
            ((Value[Index] >= 'a') and (Value[Index] <= 'f')) or
            ((Value[Index] >= 'A') and (Value[Index] <= 'F'))) then exit;
  Result := True;
end;

function IsValidUninstallerMeta(const Meta: String): Boolean;
var
  Separator: Integer;
  SizeText, Digest: String;
begin
  Result := False;
  Separator := Pos('|', Meta);
  if Separator < 2 then exit;
  SizeText := Copy(Meta, 1, Separator - 1);
  Digest := Copy(Meta, Separator + 1, Length(Meta) - Separator);
  if (Pos('|', Digest) <> 0) or (StrToInt64Def(SizeText, -1) < 0) or
     (not IsSHA256Digest(Digest)) then exit;
  Result := True;
end;

function RegistrationDigestWithUninstallerMeta(const ExeMeta, DatMeta: String;
  var Found: Boolean): String;
var
  Key, DisplayName, DisplayVersion, InstallLocation, UninstallString, QuietUninstallString: String;
  QuietValue: String;
begin
  Key := 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{8F488698-AB96-45DB-A2BB-D9E868823F43}_is1';
  Found := RegQueryStringValue(HKEY_LOCAL_MACHINE, Key, 'DisplayName', DisplayName) and
           RegQueryStringValue(HKEY_LOCAL_MACHINE, Key, 'DisplayVersion', DisplayVersion) and
           RegQueryStringValue(HKEY_LOCAL_MACHINE, Key, 'InstallLocation', InstallLocation) and
           RegQueryStringValue(HKEY_LOCAL_MACHINE, Key, 'UninstallString', UninstallString);
  if not Found then begin if RegKeyExists(HKEY_LOCAL_MACHINE, Key) then Result := 'INVALID' else Result := 'NONE'; exit; end;
  if CompareText(NormalizedPath(InstallLocation), AppRoot) <> 0 then begin Result := 'INVALID'; exit; end;
  if (not IsValidUninstallerMeta(ExeMeta)) or (not IsValidUninstallerMeta(DatMeta)) then
  begin Result := 'INVALID'; exit; end;
  if RegQueryStringValue(HKEY_LOCAL_MACHINE, Key, 'QuietUninstallString', QuietUninstallString) then
    QuietValue := 'PRESENT|' + QuietUninstallString
  else QuietValue := 'MISSING';
  Result := GetSHA256OfUnicodeString(DisplayName + #10 + DisplayVersion + #10 +
    NormalizedPath(InstallLocation) + #10 + UninstallString + #10 + QuietValue + #10 +
    ExeMeta + #10 + DatMeta);
end;

function RegistrationDigest(var Found: Boolean): String;
var
  ExeMeta, DatMeta: String;
begin
  if (not CurrentUninstallerMeta('unins000.exe', ExeMeta)) or
     (not CurrentUninstallerMeta('unins000.dat', DatMeta)) then
  begin
    Found := RegKeyExists(HKEY_LOCAL_MACHINE,
      'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{8F488698-AB96-45DB-A2BB-D9E868823F43}_is1');
    if Found then Result := 'INVALID' else Result := 'NONE';
    exit;
  end;
  Result := RegistrationDigestWithUninstallerMeta(ExeMeta, DatMeta, Found);
end;

function UninstallKey: String;
begin
  Result := 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{8F488698-AB96-45DB-A2BB-D9E868823F43}_is1';
end;

procedure GetRegistrationStringNames(var Names: TArrayOfString);
begin
  SetArrayLength(Names, 16);
  Names[0] := 'DisplayName'; Names[1] := 'DisplayVersion'; Names[2] := 'Publisher';
  Names[3] := 'InstallLocation'; Names[4] := 'UninstallString'; Names[5] := 'QuietUninstallString';
  Names[6] := 'DisplayIcon'; Names[7] := 'InstallDate'; Names[8] := 'Inno Setup: App Path';
  Names[9] := 'Inno Setup: Icon Group'; Names[10] := 'Inno Setup: User';
  Names[11] := 'Inno Setup: Selected Tasks'; Names[12] := 'Inno Setup: Language';
  Names[13] := 'Inno Setup: Setup Version'; Names[14] := 'Inno Setup: Privileges Required';
  Names[15] := 'Inno Setup: Architectures Allowed';
end;

procedure GetRegistrationDwordNames(var Names: TArrayOfString);
begin
  SetArrayLength(Names, 5);
  Names[0] := 'NoModify'; Names[1] := 'NoRepair'; Names[2] := 'EstimatedSize';
  Names[3] := 'MajorVersion'; Names[4] := 'MinorVersion';
end;

function EncodeRegistryString(const Value: String): String;
var Index, Code: Integer;
    Digits: String;
begin
  Result := ''; Digits := '0123456789ABCDEF';
  for Index := 1 to Length(Value) do
  begin
    Code := Ord(Value[Index]);
    Result := Result + Digits[(Code div 4096) + 1] + Digits[((Code div 256) mod 16) + 1] +
      Digits[((Code div 16) mod 16) + 1] + Digits[(Code mod 16) + 1];
  end;
end;

function HexNibble(const C: Char): Integer;
begin
  if (C >= '0') and (C <= '9') then Result := Ord(C) - Ord('0')
  else if (C >= 'A') and (C <= 'F') then Result := Ord(C) - Ord('A') + 10
  else Result := -1;
end;

function DecodeRegistryString(const Value: String; var Decoded: String): Boolean;
var Index, Code, N1, N2, N3, N4: Integer;
begin
  Result := False; Decoded := '';
  if (Length(Value) mod 4) <> 0 then exit;
  Index := 1;
  while Index <= Length(Value) do
  begin
    N1 := HexNibble(Value[Index]); N2 := HexNibble(Value[Index + 1]);
    N3 := HexNibble(Value[Index + 2]); N4 := HexNibble(Value[Index + 3]);
    if (N1 < 0) or (N2 < 0) or (N3 < 0) or (N4 < 0) then exit;
    Code := N1 * 4096 + N2 * 256 + N3 * 16 + N4;
    Decoded := Decoded + Chr(Code);
    Index := Index + 4;
  end;
  Result := True;
end;

procedure SnapshotPriorRegistration(const RecoveryRoot: String; var SnapshotHash: String);
var Lines, StringNames, DwordNames: TArrayOfString;
    Index, Offset: Integer;
    StringValue: String;
    DwordValue: Cardinal;
begin
  if not RegKeyExists(HKEY_LOCAL_MACHINE, UninstallKey) then
  begin
    SetArrayLength(Lines, 1); Lines[0] := 'KEY|ABSENT';
  end
  else
  begin
    GetRegistrationStringNames(StringNames); GetRegistrationDwordNames(DwordNames);
    SetArrayLength(Lines, 1 + GetArrayLength(StringNames) + GetArrayLength(DwordNames));
    Lines[0] := 'KEY|PRESENT'; Offset := 1;
    for Index := 0 to GetArrayLength(StringNames) - 1 do
    begin
      if RegValueExists(HKEY_LOCAL_MACHINE, UninstallKey, StringNames[Index]) then
      begin
        if not RegQueryStringValue(HKEY_LOCAL_MACHINE, UninstallKey, StringNames[Index], StringValue) then
          RaiseException('Setup refused an unsupported registration value type.');
        Lines[Offset] := 'S|' + StringNames[Index] + '|' + EncodeRegistryString(StringValue);
      end else Lines[Offset] := 'M|' + StringNames[Index];
      Offset := Offset + 1;
    end;
    for Index := 0 to GetArrayLength(DwordNames) - 1 do
    begin
      if RegValueExists(HKEY_LOCAL_MACHINE, UninstallKey, DwordNames[Index]) then
      begin
        if not RegQueryDWordValue(HKEY_LOCAL_MACHINE, UninstallKey, DwordNames[Index], DwordValue) then
          RaiseException('Setup refused an unsupported registration value type.');
        Lines[Offset] := 'D|' + DwordNames[Index] + '|' + IntToStr(DwordValue);
      end else Lines[Offset] := 'M|' + DwordNames[Index];
      Offset := Offset + 1;
    end;
  end;
  AtomicWriteLines(RecoveryChild(RecoveryRoot, 'prior-registration.txt'), Lines);
  SnapshotHash := GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'prior-registration.txt'));
end;

function RestorePriorRegistration(const RecoveryRoot, SnapshotHash: String): Boolean;
var Lines, StringNames, DwordNames: TArrayOfString;
    Index, Offset: Integer;
    ExpectedPrefix, Encoded, Decoded: String;
    DwordValue: Int64;
begin
  Result := False;
  if (not FileExists(RecoveryChild(RecoveryRoot, 'prior-registration.txt'))) or
     IsReparsePath(RecoveryChild(RecoveryRoot, 'prior-registration.txt')) or
     (CompareText(GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'prior-registration.txt')), SnapshotHash) <> 0) or
     (not LoadStringsFromFile(RecoveryChild(RecoveryRoot, 'prior-registration.txt'), Lines)) then exit;
  if (GetArrayLength(Lines) = 1) and (Lines[0] = 'KEY|ABSENT') then
  begin
    RegDeleteKeyIncludingSubkeys(HKEY_LOCAL_MACHINE, UninstallKey);
    Result := not RegKeyExists(HKEY_LOCAL_MACHINE, UninstallKey); exit;
  end;
  GetRegistrationStringNames(StringNames); GetRegistrationDwordNames(DwordNames);
  if (GetArrayLength(Lines) <> 1 + GetArrayLength(StringNames) + GetArrayLength(DwordNames)) or
     (Lines[0] <> 'KEY|PRESENT') then exit;
  RegDeleteKeyIncludingSubkeys(HKEY_LOCAL_MACHINE, UninstallKey);
  Offset := 1;
  for Index := 0 to GetArrayLength(StringNames) - 1 do
  begin
    ExpectedPrefix := 'S|' + StringNames[Index] + '|';
    if Lines[Offset] = 'M|' + StringNames[Index] then
    else if Pos(ExpectedPrefix, Lines[Offset]) = 1 then
    begin
      Encoded := Copy(Lines[Offset], Length(ExpectedPrefix) + 1, Length(Lines[Offset]));
      if (not DecodeRegistryString(Encoded, Decoded)) or
         (not RegWriteStringValue(HKEY_LOCAL_MACHINE, UninstallKey, StringNames[Index], Decoded)) then exit;
    end else exit;
    Offset := Offset + 1;
  end;
  for Index := 0 to GetArrayLength(DwordNames) - 1 do
  begin
    ExpectedPrefix := 'D|' + DwordNames[Index] + '|';
    if Lines[Offset] = 'M|' + DwordNames[Index] then
    else if Pos(ExpectedPrefix, Lines[Offset]) = 1 then
    begin
      DwordValue := StrToInt64Def(Copy(Lines[Offset], Length(ExpectedPrefix) + 1, Length(Lines[Offset])), -1);
      if (DwordValue < 0) or (DwordValue > 4294967295) or
         (not RegWriteDWordValue(HKEY_LOCAL_MACHINE, UninstallKey, DwordNames[Index], DwordValue)) then exit;
    end else exit;
    Offset := Offset + 1;
  end;
  Result := CompareText(GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'prior-registration.txt')), SnapshotHash) = 0;
end;

function VerifyPriorRegistration(const RecoveryRoot, SnapshotHash: String): Boolean;
var
  Lines, StringNames, DwordNames: TArrayOfString;
  Index, Offset: Integer;
  ExpectedPrefix, Encoded, Decoded, ActualString: String;
  ExpectedDword: Int64;
  ActualDword: Cardinal;
begin
  Result := False;
  if (not LoadStringsFromFile(RecoveryChild(RecoveryRoot, 'prior-registration.txt'), Lines)) or
     IsReparsePath(RecoveryChild(RecoveryRoot, 'prior-registration.txt')) or
     (CompareText(GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'prior-registration.txt')), SnapshotHash) <> 0) then exit;
  if (GetArrayLength(Lines) = 1) and (Lines[0] = 'KEY|ABSENT') then
  begin Result := not RegKeyExists(HKEY_LOCAL_MACHINE, UninstallKey); exit; end;
  GetRegistrationStringNames(StringNames); GetRegistrationDwordNames(DwordNames);
  if (GetArrayLength(Lines) <> 1 + GetArrayLength(StringNames) + GetArrayLength(DwordNames)) or
     (Lines[0] <> 'KEY|PRESENT') or (not RegKeyExists(HKEY_LOCAL_MACHINE, UninstallKey)) then exit;
  Offset := 1;
  for Index := 0 to GetArrayLength(StringNames) - 1 do
  begin
    ExpectedPrefix := 'S|' + StringNames[Index] + '|';
    if Lines[Offset] = 'M|' + StringNames[Index] then
    begin if RegValueExists(HKEY_LOCAL_MACHINE, UninstallKey, StringNames[Index]) then exit; end
    else if Pos(ExpectedPrefix, Lines[Offset]) = 1 then
    begin
      Encoded := Copy(Lines[Offset], Length(ExpectedPrefix) + 1, Length(Lines[Offset]));
      if (not DecodeRegistryString(Encoded, Decoded)) or
         (not RegQueryStringValue(HKEY_LOCAL_MACHINE, UninstallKey, StringNames[Index], ActualString)) or
         (ActualString <> Decoded) then exit;
    end else exit;
    Offset := Offset + 1;
  end;
  for Index := 0 to GetArrayLength(DwordNames) - 1 do
  begin
    ExpectedPrefix := 'D|' + DwordNames[Index] + '|';
    if Lines[Offset] = 'M|' + DwordNames[Index] then
    begin if RegValueExists(HKEY_LOCAL_MACHINE, UninstallKey, DwordNames[Index]) then exit; end
    else if Pos(ExpectedPrefix, Lines[Offset]) = 1 then
    begin
      ExpectedDword := StrToInt64Def(Copy(Lines[Offset], Length(ExpectedPrefix) + 1, Length(Lines[Offset])), -1);
      if (ExpectedDword < 0) or (not RegQueryDWordValue(HKEY_LOCAL_MACHINE, UninstallKey,
        DwordNames[Index], ActualDword)) or (ActualDword <> ExpectedDword) then exit;
    end else exit;
    Offset := Offset + 1;
  end;
  Result := True;
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
  var TransactionId, OldManifestHash, IncomingManifestHash, IncomingHashesHash,
      PriorRegistrationHash, PriorUninsExeMeta, PriorUninsDatMeta, RegistrationHash: String): Boolean;
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
  if GetArrayLength(Lines) < 13 then exit;
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
  if Pos('PRIORREGISTRATION|', Lines[7]) <> 1 then exit;
  PriorRegistrationHash := Copy(Lines[7], 19, Length(Lines[7]) - 18);
  if Pos('PRIORUNINSEXE|', Lines[8]) <> 1 then exit;
  PriorUninsExeMeta := Copy(Lines[8], 15, Length(Lines[8]) - 14);
  if Pos('PRIORUNINSDAT|', Lines[9]) <> 1 then exit;
  PriorUninsDatMeta := Copy(Lines[9], 15, Length(Lines[9]) - 14);
  if Pos('REGISTRATION|', Lines[10]) <> 1 then exit;
  RegistrationHash := Copy(Lines[10], 14, Length(Lines[10]) - 13);
  if Pos('COUNT|', Lines[11]) <> 1 then exit;
  EntryCount := StrToIntDef(Copy(Lines[11], 7, Length(Lines[11]) - 6), -1);
  if (EntryCount < 1) or (GetArrayLength(Lines) <> EntryCount + 12) then exit;
  Log('Durable state validation: header accepted.');
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
  if IsReparsePath(RecoveryChild(RecoveryRoot, 'prior-registration.txt')) or
     (not FileExists(RecoveryChild(RecoveryRoot, 'prior-registration.txt'))) or
     (CompareText(GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'prior-registration.txt')), PriorRegistrationHash) <> 0) then exit;
  if (PriorUninsExeMeta = 'NONE') <> (PriorUninsDatMeta = 'NONE') then exit;
  if PriorUninsExeMeta <> 'NONE' then
  begin
    Separator1 := Pos('|', PriorUninsExeMeta); Separator2 := Pos('|', PriorUninsDatMeta);
    if (Separator1 < 2) or (Separator2 < 2) or
       (not FileExists(RecoveryChild(RecoveryRoot, 'prior-unins.exe'))) or
       (not FileExists(RecoveryChild(RecoveryRoot, 'prior-unins.dat'))) or
       IsReparsePath(RecoveryChild(RecoveryRoot, 'prior-unins.exe')) or
       IsReparsePath(RecoveryChild(RecoveryRoot, 'prior-unins.dat')) or
       (not TryGetFileSizeText(RecoveryChild(RecoveryRoot, 'prior-unins.exe'), ActualSizeText)) or
       (ActualSizeText <> Copy(PriorUninsExeMeta, 1, Separator1 - 1)) or
       (CompareText(GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'prior-unins.exe')), Copy(PriorUninsExeMeta, Separator1 + 1, Length(PriorUninsExeMeta))) <> 0) or
       (not TryGetFileSizeText(RecoveryChild(RecoveryRoot, 'prior-unins.dat'), ActualSizeText)) or
       (ActualSizeText <> Copy(PriorUninsDatMeta, 1, Separator2 - 1)) or
       (CompareText(GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'prior-unins.dat')), Copy(PriorUninsDatMeta, Separator2 + 1, Length(PriorUninsDatMeta))) <> 0) then exit;
  end;
  Log('Durable state validation: metadata accepted.');

  SetArrayLength(OldPaths, 0);
  SetArrayLength(IncomingPaths, 0);
  SetArrayLength(UnionPaths, 0);
  if OldManifestHash <> 'NONE' then
    AddManifestPayloadPaths(RecoveryChild(RecoveryRoot, 'old-manifest.txt'), OldPaths, True);
  AddManifestPayloadPaths(RecoveryChild(RecoveryRoot, 'incoming-manifest.txt'), IncomingPaths, True);
  for Index := 0 to GetArrayLength(OldPaths) - 1 do AddUniquePayloadPath(UnionPaths, OldPaths[Index]);
  for Index := 0 to GetArrayLength(IncomingPaths) - 1 do AddUniquePayloadPath(UnionPaths, IncomingPaths[Index]);
  if GetArrayLength(UnionPaths) <> EntryCount then exit;
  Log('Durable state validation: manifest union accepted.');

  SetArrayLength(Entries, EntryCount);
  SetArrayLength(ParsedPaths, 0);
  ExistingCount := 0;
  for Index := 0 to EntryCount - 1 do
  begin
    EntryText := Lines[Index + 12];
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
  Log('Durable state validation: entries and backup accepted.');
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

function CurrentUninstallerMeta(const FileName: String; var Meta: String): Boolean;
var Path, SizeText: String;
begin
  Path := AddBackslash(AppRoot) + FileName;
  Result := FileExists(Path) and (not IsReparsePath(Path)) and TryGetFileSizeText(Path, SizeText);
  if Result then Meta := SizeText + '|' + GetSHA256OfFile(Path);
end;

function WritePriorUninstallerProof(const RecoveryRoot: String): Boolean;
var
  Entries: TPayloadEntries;
  Lines: TArrayOfString;
  TransactionId, OldManifestHash, IncomingManifestHash, IncomingHashesHash,
  PriorRegistrationHash, PriorUninsExeMeta, PriorUninsDatMeta, PriorDigest,
  StateHash, ExeMeta, DatMeta: String;
begin
  Result := False;
  if InsideUninstaller then exit;
  if not TryParseState(RecoveryRoot, Entries, TransactionId, OldManifestHash,
    IncomingManifestHash, IncomingHashesHash, PriorRegistrationHash,
    PriorUninsExeMeta, PriorUninsDatMeta, PriorDigest) then exit;
  if (PriorUninsExeMeta = 'NONE') or
     (not CurrentUninstallerMeta('unins000.exe', ExeMeta)) or
     (not CurrentUninstallerMeta('unins000.dat', DatMeta)) or
     (CompareText(ExeMeta, PriorUninsExeMeta) <> 0) or
     (CompareText(DatMeta, PriorUninsDatMeta) <> 0) then exit;
  StateHash := GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'state.txt'));
  SetArrayLength(Lines, 8);
  Lines[0] := AMMAR_UNINS_PROOF_MAGIC; Lines[1] := 'APPID|' + AMMAR_APP_ID;
  Lines[2] := 'ROOT|' + AppRoot; Lines[3] := 'TXID|' + TransactionId;
  Lines[4] := 'STATE|' + StateHash; Lines[5] := 'PRIORUNINSEXE|' + PriorUninsExeMeta;
  Lines[6] := 'PRIORUNINSDAT|' + PriorUninsDatMeta;
  Lines[7] := 'PRIORREGISTRATION|' + PriorRegistrationHash;
  AtomicWriteLines(RecoveryChild(RecoveryRoot, 'prior-uninstaller-verified.txt'), Lines);
  AtomicWriteText(RecoveryChild(RecoveryRoot, 'prior-uninstaller-verified.sha256'),
    GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'prior-uninstaller-verified.txt')));
  Result := True;
end;

function ValidatePriorUninstallerProof(const RecoveryRoot: String): Boolean;
var
  Entries: TPayloadEntries;
  Lines: TArrayOfString;
  TransactionId, OldManifestHash, IncomingManifestHash, IncomingHashesHash,
  PriorRegistrationHash, PriorUninsExeMeta, PriorUninsDatMeta, PriorDigest,
  StateHash, ExpectedHash, ExeMeta: String;
begin
  Result := False;
  if not TryParseState(RecoveryRoot, Entries, TransactionId, OldManifestHash,
    IncomingManifestHash, IncomingHashesHash, PriorRegistrationHash,
    PriorUninsExeMeta, PriorUninsDatMeta, PriorDigest) then exit;
  if IsReparsePath(RecoveryChild(RecoveryRoot, 'prior-uninstaller-verified.txt')) or
     IsReparsePath(RecoveryChild(RecoveryRoot, 'prior-uninstaller-verified.sha256')) or
     (not LoadStringsFromFile(RecoveryChild(RecoveryRoot, 'prior-uninstaller-verified.txt'), Lines)) or
     (GetArrayLength(Lines) <> 8) or
     (not LoadSingleLine(RecoveryChild(RecoveryRoot, 'prior-uninstaller-verified.sha256'), ExpectedHash)) or
     (CompareText(GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'prior-uninstaller-verified.txt')), Trim(ExpectedHash)) <> 0) then exit;
  StateHash := GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'state.txt'));
  if (Lines[0] <> AMMAR_UNINS_PROOF_MAGIC) or (Lines[1] <> 'APPID|' + AMMAR_APP_ID) or
     (Lines[2] <> 'ROOT|' + AppRoot) or (Lines[3] <> 'TXID|' + TransactionId) or
     (Lines[4] <> 'STATE|' + StateHash) or
     (Lines[5] <> 'PRIORUNINSEXE|' + PriorUninsExeMeta) or
     (Lines[6] <> 'PRIORUNINSDAT|' + PriorUninsDatMeta) or
     (Lines[7] <> 'PRIORREGISTRATION|' + PriorRegistrationHash) or
     (not CurrentUninstallerMeta('unins000.exe', ExeMeta)) or
     (CompareText(ExeMeta, PriorUninsExeMeta) <> 0) or
     (not VerifyPriorRegistration(RecoveryRoot, PriorRegistrationHash)) then exit;
  Result := True;
end;

function RemoveObsoleteProductPayload(const RecoveryRoot: String): Boolean;
var
  Entries: TPayloadEntries;
  OldPaths, IncomingPaths: TArrayOfString;
  Index: Integer;
  TransactionId, OldManifestHash, IncomingManifestHash, IncomingHashesHash,
  PriorRegistrationHash, PriorUninsExeMeta, PriorUninsDatMeta, PriorDigest,
  ObsoletePath: String;
begin
  Result := False;
  if not TryParseState(RecoveryRoot, Entries, TransactionId, OldManifestHash,
    IncomingManifestHash, IncomingHashesHash, PriorRegistrationHash,
    PriorUninsExeMeta, PriorUninsDatMeta, PriorDigest) then exit;
  if OldManifestHash = 'NONE' then begin Result := True; exit; end;
  SetArrayLength(OldPaths, 0);
  SetArrayLength(IncomingPaths, 0);
  AddManifestPayloadPaths(RecoveryChild(RecoveryRoot, 'old-manifest.txt'), OldPaths, True);
  AddManifestPayloadPaths(RecoveryChild(RecoveryRoot, 'incoming-manifest.txt'), IncomingPaths, True);
  for Index := 0 to GetArrayLength(OldPaths) - 1 do
    if not ContainsPayloadPath(IncomingPaths, OldPaths[Index]) then
    begin
      if not IsContainedNonReparsePayloadPath(OldPaths[Index]) then exit;
      ObsoletePath := AddBackslash(AppRoot) + OldPaths[Index];
      if DirExists(ObsoletePath) then exit;
      if FileExists(ObsoletePath) and (not DeleteFile(ObsoletePath)) then exit;
    end;
  Result := True;
end;

function IncomingProofPathsAreNonReparse(const RecoveryRoot: String): Boolean;
var
  ProofPath, ProofHashPath: String;
begin
  ProofPath := RecoveryChild(RecoveryRoot, 'incoming-uninstaller-verified.txt');
  ProofHashPath := RecoveryChild(RecoveryRoot, 'incoming-uninstaller-verified.sha256');
  Result := IsExactRecoveryRootSafe(RecoveryRoot) and
            (not IsReparsePath(ProofPath)) and
            (not IsReparsePath(ProofPath + '.new')) and
            (not IsReparsePath(ProofHashPath)) and
            (not IsReparsePath(ProofHashPath + '.new'));
end;

function ValidateIncomingUninstallerProofEnvelope(const RecoveryRoot, TransactionId, StateHash,
  MarkerHash, IncomingManifestHash, IncomingHashesHash, RegistrationHash,
  ExeMeta, DatMeta: String): Boolean;
var
  Lines: TArrayOfString;
  ProofPath, ProofHashPath, ExpectedProofHash: String;
begin
  Result := False;
  ProofPath := RecoveryChild(RecoveryRoot, 'incoming-uninstaller-verified.txt');
  ProofHashPath := RecoveryChild(RecoveryRoot, 'incoming-uninstaller-verified.sha256');
  if (not IncomingProofPathsAreNonReparse(RecoveryRoot)) or
     (not FileExists(ProofPath)) or (not FileExists(ProofHashPath)) or
     (not LoadStringsFromFile(ProofPath, Lines)) or (GetArrayLength(Lines) <> 11) or
     (not LoadSingleLine(ProofHashPath, ExpectedProofHash)) or
     (not IsSHA256Digest(Trim(ExpectedProofHash))) or
     (CompareText(GetSHA256OfFile(ProofPath), Trim(ExpectedProofHash)) <> 0) then exit;
  if (Lines[0] <> AMMAR_INCOMING_UNINS_PROOF_MAGIC) or
     (Lines[1] <> 'APPID|' + AMMAR_APP_ID) or
     (Lines[2] <> 'ROOT|' + AppRoot) or
     (Lines[3] <> 'TXID|' + TransactionId) or
     (Lines[4] <> 'STATE|' + StateHash) or
     (Lines[5] <> 'COMMITTED|' + MarkerHash) or
     (Lines[6] <> 'INCOMINGMANIFEST|' + IncomingManifestHash) or
     (Lines[7] <> 'INCOMINGHASHES|' + IncomingHashesHash) or
     (Lines[8] <> 'REGISTRATION|' + RegistrationHash) or
     (Lines[9] <> 'UNINSEXE|' + ExeMeta) or
     (Lines[10] <> 'UNINSDAT|' + DatMeta) or
     (not IsSHA256Digest(StateHash)) or (not IsSHA256Digest(MarkerHash)) or
     (not IsSHA256Digest(IncomingManifestHash)) or
     (not IsSHA256Digest(IncomingHashesHash)) or
     (not IsSHA256Digest(RegistrationHash)) or
     (not IsValidUninstallerMeta(ExeMeta)) or
     (not IsValidUninstallerMeta(DatMeta)) then exit;
  Result := True;
end;

function ValidateIncomingUninstallerProof(const RecoveryRoot, TransactionId, StateHash,
  MarkerHash, IncomingManifestHash, IncomingHashesHash, RegistrationHash,
  ExeMeta, DatMeta: String): Boolean;
var
  CurrentExeMeta, CurrentDigest, CurrentDatPath: String;
  RegistrationFound: Boolean;
begin
  Result := False;
  if not ValidateIncomingUninstallerProofEnvelope(RecoveryRoot, TransactionId,
    StateHash, MarkerHash, IncomingManifestHash, IncomingHashesHash,
    RegistrationHash, ExeMeta, DatMeta) then exit;
  CurrentDatPath := AddBackslash(AppRoot) + 'unins000.dat';
  if (not CurrentUninstallerMeta('unins000.exe', CurrentExeMeta)) or
     (CompareText(CurrentExeMeta, ExeMeta) <> 0) or
     (not FileExists(CurrentDatPath)) or IsReparsePath(CurrentDatPath) then exit;
  CurrentDigest := RegistrationDigestWithUninstallerMeta(ExeMeta, DatMeta, RegistrationFound);
  if (not RegistrationFound) or (CompareText(CurrentDigest, RegistrationHash) <> 0) or
     (not VerifyIncomingCommittedPayload(RecoveryRoot, IncomingManifestHash,
       IncomingHashesHash)) then exit;
  Log('Durable incoming uninstaller proof accepted.');
  Result := True;
end;

function ValidateCommittedMarker(const RecoveryRoot: String): Boolean;
var
  Entries: TPayloadEntries;
  Lines: TArrayOfString;
  TransactionId, OldManifestHash, IncomingManifestHash, IncomingHashesHash,
  PriorRegistrationHash, PriorUninsExeMeta, PriorUninsDatMeta, PriorDigest,
  StateHash, ExpectedMarkerHash, MarkerHash, CurrentDigest, ExeMeta, DatMeta: String;
  RegistrationFound: Boolean;
begin
  Result := False;
  if not TryParseState(RecoveryRoot, Entries, TransactionId, OldManifestHash,
    IncomingManifestHash, IncomingHashesHash, PriorRegistrationHash,
    PriorUninsExeMeta, PriorUninsDatMeta, PriorDigest) then exit;
  if IsReparsePath(RecoveryChild(RecoveryRoot, 'committed.txt')) or
     IsReparsePath(RecoveryChild(RecoveryRoot, 'committed.sha256')) or
     (not LoadStringsFromFile(RecoveryChild(RecoveryRoot, 'committed.txt'), Lines)) or
     (GetArrayLength(Lines) <> 10) or
     (not LoadSingleLine(RecoveryChild(RecoveryRoot, 'committed.sha256'), ExpectedMarkerHash)) or
     (CompareText(GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'committed.txt')), Trim(ExpectedMarkerHash)) <> 0) then exit;
  StateHash := GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'state.txt'));
  MarkerHash := GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'committed.txt'));
  if (Lines[0] <> AMMAR_COMMIT_MAGIC) or (Lines[1] <> 'APPID|' + AMMAR_APP_ID) or
     (Lines[2] <> 'ROOT|' + AppRoot) or (Lines[3] <> 'TXID|' + TransactionId) or
     (Lines[4] <> 'STATE|' + StateHash) or
     (Lines[5] <> 'INCOMINGMANIFEST|' + IncomingManifestHash) or
     (Lines[6] <> 'INCOMINGHASHES|' + IncomingHashesHash) or
     (Pos('REGISTRATION|', Lines[7]) <> 1) or
     (Pos('UNINSEXE|', Lines[8]) <> 1) or (Pos('UNINSDAT|', Lines[9]) <> 1) or
     (not IsSHA256Digest(Copy(Lines[7], 14, Length(Lines[7])))) or
     (not IsValidUninstallerMeta(Copy(Lines[8], 10, Length(Lines[8])))) or
     (not IsValidUninstallerMeta(Copy(Lines[9], 10, Length(Lines[9])))) then exit;
  if InsideUninstaller then
  begin
    Result := ValidateIncomingUninstallerProof(RecoveryRoot, TransactionId, StateHash,
      MarkerHash, IncomingManifestHash, IncomingHashesHash,
      Copy(Lines[7], 14, Length(Lines[7])), Copy(Lines[8], 10, Length(Lines[8])),
      Copy(Lines[9], 10, Length(Lines[9])));
    exit;
  end;
  CurrentDigest := RegistrationDigest(RegistrationFound);
  if (not RegistrationFound) or
     (CompareText(CurrentDigest, Copy(Lines[7], 14, Length(Lines[7]))) <> 0) or
     (not CurrentUninstallerMeta('unins000.exe', ExeMeta)) or
     (not CurrentUninstallerMeta('unins000.dat', DatMeta)) or
     (CompareText(ExeMeta, Copy(Lines[8], 10, Length(Lines[8]))) <> 0) or
     (CompareText(DatMeta, Copy(Lines[9], 10, Length(Lines[9]))) <> 0) or
     (not VerifyIncomingCommittedPayload(RecoveryRoot, IncomingManifestHash, IncomingHashesHash)) then exit;
  Result := True;
end;

function WriteIncomingUninstallerProof(const RecoveryRoot, TransactionId, StateHash,
  MarkerHash, IncomingManifestHash, IncomingHashesHash, RegistrationHash,
  ExeMeta, DatMeta: String): Boolean;
var
  MarkerLines, ProofLines: TArrayOfString;
  ExpectedStateHash, Phase, ExpectedMarkerHash, ProofPath, ProofHashPath,
  CurrentExeMeta, CurrentDatMeta, CurrentDigest: String;
  RegistrationFound: Boolean;
begin
  Result := False;
  if InsideUninstaller or (not IsExactRecoveryRootSafe(RecoveryRoot)) or
     (not IncomingProofPathsAreNonReparse(RecoveryRoot)) or
     (not LoadSingleLine(RecoveryChild(RecoveryRoot, 'state.sha256'), ExpectedStateHash)) or
     (CompareText(Trim(ExpectedStateHash), StateHash) <> 0) or
     (CompareText(GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'state.txt')), StateHash) <> 0) or
     (not LoadSingleLine(RecoveryChild(RecoveryRoot, 'phase.txt'), Phase)) or
     (Phase <> 'ACTIVE|' + TransactionId + '|' + StateHash) or
     (not LoadStringsFromFile(RecoveryChild(RecoveryRoot, 'committed.txt'), MarkerLines)) or
     (GetArrayLength(MarkerLines) <> 10) or
     (not LoadSingleLine(RecoveryChild(RecoveryRoot, 'committed.sha256'), ExpectedMarkerHash)) or
     (CompareText(Trim(ExpectedMarkerHash), MarkerHash) <> 0) or
     (CompareText(GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'committed.txt')), MarkerHash) <> 0) or
     (MarkerLines[0] <> AMMAR_COMMIT_MAGIC) or
     (MarkerLines[1] <> 'APPID|' + AMMAR_APP_ID) or
     (MarkerLines[2] <> 'ROOT|' + AppRoot) or
     (MarkerLines[3] <> 'TXID|' + TransactionId) or
     (MarkerLines[4] <> 'STATE|' + StateHash) or
     (MarkerLines[5] <> 'INCOMINGMANIFEST|' + IncomingManifestHash) or
     (MarkerLines[6] <> 'INCOMINGHASHES|' + IncomingHashesHash) or
     (MarkerLines[7] <> 'REGISTRATION|' + RegistrationHash) or
     (MarkerLines[8] <> 'UNINSEXE|' + ExeMeta) or
     (MarkerLines[9] <> 'UNINSDAT|' + DatMeta) or
     (CompareText(GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'incoming-manifest.txt')),
       IncomingManifestHash) <> 0) or
     (CompareText(GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'incoming-hashes.txt')),
       IncomingHashesHash) <> 0) or
     (not CurrentUninstallerMeta('unins000.exe', CurrentExeMeta)) or
     (not CurrentUninstallerMeta('unins000.dat', CurrentDatMeta)) or
     (CompareText(CurrentExeMeta, ExeMeta) <> 0) or
     (CompareText(CurrentDatMeta, DatMeta) <> 0) or
     (not VerifyIncomingCommittedPayload(RecoveryRoot, IncomingManifestHash,
       IncomingHashesHash)) then exit;
  CurrentDigest := RegistrationDigestWithUninstallerMeta(CurrentExeMeta,
    CurrentDatMeta, RegistrationFound);
  if (not RegistrationFound) or (CompareText(CurrentDigest, RegistrationHash) <> 0) then exit;
  SetArrayLength(ProofLines, 11);
  ProofLines[0] := AMMAR_INCOMING_UNINS_PROOF_MAGIC;
  ProofLines[1] := 'APPID|' + AMMAR_APP_ID;
  ProofLines[2] := 'ROOT|' + AppRoot;
  ProofLines[3] := 'TXID|' + TransactionId;
  ProofLines[4] := 'STATE|' + StateHash;
  ProofLines[5] := 'COMMITTED|' + MarkerHash;
  ProofLines[6] := 'INCOMINGMANIFEST|' + IncomingManifestHash;
  ProofLines[7] := 'INCOMINGHASHES|' + IncomingHashesHash;
  ProofLines[8] := 'REGISTRATION|' + RegistrationHash;
  ProofLines[9] := 'UNINSEXE|' + ExeMeta;
  ProofLines[10] := 'UNINSDAT|' + DatMeta;
  ProofPath := RecoveryChild(RecoveryRoot, 'incoming-uninstaller-verified.txt');
  ProofHashPath := RecoveryChild(RecoveryRoot, 'incoming-uninstaller-verified.sha256');
  AtomicWriteLines(ProofPath, ProofLines);
  AtomicWriteText(ProofHashPath, GetSHA256OfFile(ProofPath));
  if not IncomingProofPathsAreNonReparse(RecoveryRoot) then exit;
  Result := ValidateIncomingUninstallerProofEnvelope(RecoveryRoot, TransactionId,
    StateHash, MarkerHash, IncomingManifestHash, IncomingHashesHash,
    RegistrationHash, ExeMeta, DatMeta);
end;

function WriteCommittedMarker(const RecoveryRoot: String): Boolean;
var
  Entries: TPayloadEntries;
  Lines: TArrayOfString;
  TransactionId, OldManifestHash, IncomingManifestHash, IncomingHashesHash,
  PriorRegistrationHash, PriorUninsExeMeta, PriorUninsDatMeta, PriorDigest,
  StateHash, CurrentDigest, ExeMeta, DatMeta, MarkerHash: String;
  RegistrationFound: Boolean;
begin
  Result := False;
  if not TryParseState(RecoveryRoot, Entries, TransactionId, OldManifestHash,
    IncomingManifestHash, IncomingHashesHash, PriorRegistrationHash,
    PriorUninsExeMeta, PriorUninsDatMeta, PriorDigest) then exit;
  if (not ValidateCanonicalIncomingMetadata) or
     (not VerifyIncomingCommittedPayload(RecoveryRoot, IncomingManifestHash, IncomingHashesHash)) or
     (not CurrentUninstallerMeta('unins000.exe', ExeMeta)) or
     (not CurrentUninstallerMeta('unins000.dat', DatMeta)) then exit;
  CurrentDigest := RegistrationDigestWithUninstallerMeta(ExeMeta, DatMeta,
    RegistrationFound);
  if (not RegistrationFound) or (not IsSHA256Digest(CurrentDigest)) then exit;
  StateHash := GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'state.txt'));
  SetArrayLength(Lines, 10);
  Lines[0] := AMMAR_COMMIT_MAGIC; Lines[1] := 'APPID|' + AMMAR_APP_ID;
  Lines[2] := 'ROOT|' + AppRoot; Lines[3] := 'TXID|' + TransactionId;
  Lines[4] := 'STATE|' + StateHash; Lines[5] := 'INCOMINGMANIFEST|' + IncomingManifestHash;
  Lines[6] := 'INCOMINGHASHES|' + IncomingHashesHash; Lines[7] := 'REGISTRATION|' + CurrentDigest;
  Lines[8] := 'UNINSEXE|' + ExeMeta; Lines[9] := 'UNINSDAT|' + DatMeta;
  AtomicWriteLines(RecoveryChild(RecoveryRoot, 'committed.txt'), Lines);
  MarkerHash := GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'committed.txt'));
  AtomicWriteText(RecoveryChild(RecoveryRoot, 'committed.sha256'), MarkerHash);
  Result := WriteIncomingUninstallerProof(RecoveryRoot, TransactionId, StateHash,
    MarkerHash, IncomingManifestHash, IncomingHashesHash, CurrentDigest, ExeMeta,
    DatMeta);
end;

function ClassifyActiveTransaction(const RecoveryRoot: String): Integer;
var
  Entries: TPayloadEntries;
  TransactionId, OldManifestHash, IncomingManifestHash, IncomingHashesHash,
  PriorRegistrationHash, PriorUninsExeMeta, PriorUninsDatMeta, RegistrationHash: String;
begin
  Result := AMMAR_TX_INVALID;
  if (not IsExactRecoveryRootSafe(RecoveryRoot)) or
     (not TryParseState(RecoveryRoot, Entries, TransactionId, OldManifestHash,
       IncomingManifestHash, IncomingHashesHash, PriorRegistrationHash,
       PriorUninsExeMeta, PriorUninsDatMeta, RegistrationHash)) then exit;
  if FileExists(RecoveryChild(RecoveryRoot, 'committed.txt')) or
     FileExists(RecoveryChild(RecoveryRoot, 'committed.sha256')) then
  begin
    if ValidateCommittedMarker(RecoveryRoot) then Result := AMMAR_TX_INCOMING;
  end
  else Result := AMMAR_TX_PRIOR;
end;

procedure SetRecoveryPhase(const RecoveryRoot, Phase, TransactionId, StateHash: String);
begin
  AtomicWriteText(RecoveryChild(RecoveryRoot, 'phase.txt'), Phase + '|' + TransactionId + '|' + StateHash);
end;

function VerifyRestoredPayload(const RecoveryRoot: String; const Entries: TPayloadEntries;
  const OldManifestHash, RegistrationHash, PriorRegistrationHash: String): Boolean;
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
  if UninstallUsesPriorProof then
  begin
    if not VerifyPriorRegistration(RecoveryRoot, PriorRegistrationHash) then exit;
  end
  else
  begin
    CurrentRegistrationHash := RegistrationDigest(RegistrationFound);
    if CompareText(CurrentRegistrationHash, RegistrationHash) <> 0 then exit;
  end;
  Result := True;
end;

function RestoreActiveTransaction(const RecoveryRoot: String): Boolean;
var
  Entries: TPayloadEntries;
  TransactionId, OldManifestHash, IncomingManifestHash, IncomingHashesHash,
  PriorRegistrationHash, PriorUninsExeMeta, PriorUninsDatMeta, RegistrationHash: String;
  InstalledPath, BackupPath, StateHash, RestoredExeMeta, RestoredDatMeta: String;
  Index: Integer;
begin
  Result := False;
  if (not IsExactRecoveryRootSafe(RecoveryRoot)) or
     (ClassifyActiveTransaction(RecoveryRoot) <> AMMAR_TX_PRIOR) or
     (not TryParseState(RecoveryRoot, Entries, TransactionId, OldManifestHash,
       IncomingManifestHash, IncomingHashesHash, PriorRegistrationHash,
       PriorUninsExeMeta, PriorUninsDatMeta, RegistrationHash)) then
  begin
    Log('ERROR: Durable recovery transaction is invalid; payload was not touched.');
    exit;
  end;
  StateHash := GetSHA256OfFile(RecoveryChild(RecoveryRoot, 'state.txt'));
  if UninstallUsesPriorProof then
  begin
    if not ValidatePriorUninstallerProof(RecoveryRoot) then exit;
  end
  else if PriorUninsExeMeta <> 'NONE' then
  begin
    if (not CurrentUninstallerMeta('unins000.exe', RestoredExeMeta)) or
       (not CurrentUninstallerMeta('unins000.dat', RestoredDatMeta)) or
       (CompareText(RestoredExeMeta, PriorUninsExeMeta) <> 0) or
       (CompareText(RestoredDatMeta, PriorUninsDatMeta) <> 0) then
    begin
      if FileExists(AddBackslash(AppRoot) + 'unins000.exe') and
         (not DeleteFile(AddBackslash(AppRoot) + 'unins000.exe')) then exit;
      if FileExists(AddBackslash(AppRoot) + 'unins000.dat') and
         (not DeleteFile(AddBackslash(AppRoot) + 'unins000.dat')) then exit;
      if (not CopyFile(RecoveryChild(RecoveryRoot, 'prior-unins.exe'), AddBackslash(AppRoot) + 'unins000.exe', False)) or
         (not CopyFile(RecoveryChild(RecoveryRoot, 'prior-unins.dat'), AddBackslash(AppRoot) + 'unins000.dat', False)) then exit;
    end;
    if (not CurrentUninstallerMeta('unins000.exe', RestoredExeMeta)) or
       (not CurrentUninstallerMeta('unins000.dat', RestoredDatMeta)) or
       (CompareText(RestoredExeMeta, PriorUninsExeMeta) <> 0) or
       (CompareText(RestoredDatMeta, PriorUninsDatMeta) <> 0) or
       (not WritePriorUninstallerProof(RecoveryRoot)) then exit;
    Log('Durable restore: prior uninstaller proof committed.');
  end;
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
  Log('Durable restore: product payload restored.');
  if (not UninstallUsesPriorProof) and (PriorUninsExeMeta = 'NONE') then
  begin
    if FileExists(AddBackslash(AppRoot) + 'unins000.exe') and
       (not DeleteFile(AddBackslash(AppRoot) + 'unins000.exe')) then exit;
    if FileExists(AddBackslash(AppRoot) + 'unins000.dat') and
       (not DeleteFile(AddBackslash(AppRoot) + 'unins000.dat')) then exit;
  end;
  Log('Durable restore: prior uninstaller metadata available.');
  if not RestorePriorRegistration(RecoveryRoot, PriorRegistrationHash) then
  begin Log('ERROR: Durable restore could not restore prior registration.'); exit; end;
  if PriorUninsExeMeta = 'NONE' then
  begin
    if FileExists(AddBackslash(AppRoot) + 'unins000.exe') or
       FileExists(AddBackslash(AppRoot) + 'unins000.dat') then exit;
  end
  else if (not UninstallUsesPriorProof) and
          ((not CurrentUninstallerMeta('unins000.exe', RestoredExeMeta)) or
          (not CurrentUninstallerMeta('unins000.dat', RestoredDatMeta)) or
          (CompareText(RestoredExeMeta, PriorUninsExeMeta) <> 0) or
          (CompareText(RestoredDatMeta, PriorUninsDatMeta) <> 0)) then exit;
  Log('Durable restore: prior installer metadata restored.');
  if not VerifyRestoredPayload(RecoveryRoot, Entries, OldManifestHash, RegistrationHash,
    PriorRegistrationHash) then
  begin
    Log('ERROR: Durable restore final payload or registration verification failed.');
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
  TransactionId, OldManifestHash, IncomingManifestHash, IncomingHashesHash,
  PriorRegistrationHash, PriorUninsExeMeta, PriorUninsDatMeta, RegistrationHash: String;
  StateHash, VerifiedRoot: String;
begin
  Result := False;
  if ClassifyActiveTransaction(RecoveryRoot) <> AMMAR_TX_INCOMING then exit;
  if not TryParseState(RecoveryRoot, Entries, TransactionId, OldManifestHash,
    IncomingManifestHash, IncomingHashesHash, PriorRegistrationHash,
    PriorUninsExeMeta, PriorUninsDatMeta, RegistrationHash) then exit;
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
  TransactionId, OldManifestHash, IncomingManifestHash, IncomingHashesHash,
  PriorRegistrationHash, PriorUninsExeMeta, PriorUninsDatMeta,
  RegistrationHash, StateHash, BackupSizeText, UninsSizeText: String;
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
  SnapshotPriorRegistration(BuildingRoot, PriorRegistrationHash);
  if FileExists(AddBackslash(AppRoot) + 'unins000.exe') or FileExists(AddBackslash(AppRoot) + 'unins000.dat') then
  begin
    if (not FileExists(AddBackslash(AppRoot) + 'unins000.exe')) or
       (not FileExists(AddBackslash(AppRoot) + 'unins000.dat')) or
       IsReparsePath(AddBackslash(AppRoot) + 'unins000.exe') or
       IsReparsePath(AddBackslash(AppRoot) + 'unins000.dat') or
       (not CopyFile(AddBackslash(AppRoot) + 'unins000.exe', RecoveryChild(BuildingRoot, 'prior-unins.exe'), False)) or
       (not CopyFile(AddBackslash(AppRoot) + 'unins000.dat', RecoveryChild(BuildingRoot, 'prior-unins.dat'), False)) then
      RaiseException('Setup could not snapshot prior installer metadata.');
    if not TryGetFileSizeText(RecoveryChild(BuildingRoot, 'prior-unins.exe'), UninsSizeText) then
      RaiseException('Setup could not measure prior installer metadata.');
    PriorUninsExeMeta := UninsSizeText + '|' + GetSHA256OfFile(RecoveryChild(BuildingRoot, 'prior-unins.exe'));
    if not TryGetFileSizeText(RecoveryChild(BuildingRoot, 'prior-unins.dat'), UninsSizeText) then
      RaiseException('Setup could not measure prior installer metadata.');
    PriorUninsDatMeta := UninsSizeText + '|' + GetSHA256OfFile(RecoveryChild(BuildingRoot, 'prior-unins.dat'));
  end
  else begin PriorUninsExeMeta := 'NONE'; PriorUninsDatMeta := 'NONE'; end;
  Log('Durable snapshot: registration bound.');
  TransactionRandom := Random(1000000000);
  Log('Durable snapshot: random suffix created.');
  TransactionId := IntToStr(TransactionRandom);
  TransactionRandom := Random(1000000000);
  TransactionId := TransactionId + '-' + IntToStr(TransactionRandom);
  Log('Durable snapshot: transaction identifier created.');
  SetArrayLength(StateLines, GetArrayLength(PayloadPaths) + 12);
  Log('Durable snapshot: state allocated.');
  StateLines[0] := AMMAR_STATE_MAGIC;
  StateLines[1] := 'APPID|' + AMMAR_APP_ID;
  StateLines[2] := 'ROOT|' + AppRoot;
  StateLines[3] := 'TXID|' + TransactionId;
  StateLines[4] := 'OLDMANIFEST|' + OldManifestHash;
  StateLines[5] := 'INCOMINGMANIFEST|' + IncomingManifestHash;
  StateLines[6] := 'INCOMINGHASHES|' + IncomingHashesHash;
  StateLines[7] := 'PRIORREGISTRATION|' + PriorRegistrationHash;
  StateLines[8] := 'PRIORUNINSEXE|' + PriorUninsExeMeta;
  StateLines[9] := 'PRIORUNINSDAT|' + PriorUninsDatMeta;
  StateLines[10] := 'REGISTRATION|' + RegistrationHash;
  StateLines[11] := 'COUNT|' + IntToStr(GetArrayLength(PayloadPaths));
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
      StateLines[Index + 12] := 'E|' + RelativePath + '|' + BackupSizeText + '|' + GetSHA256OfFile(BackupPath);
    end
    else
      StateLines[Index + 12] := 'M|' + RelativePath;
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
  InsideUninstaller := False;
  UninstallUsesPriorProof := False;
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
  if Result <> '' then exit;
  ExtractTemporaryFile('IncomingPayloadHashes.txt');
  ExtractTemporaryFile('IncomingPayloadManifest.txt');
  SnapshotProductPayload;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var Index: Integer;
begin
  if CurStep = ssPostInstall then
  begin
#ifdef AcceptanceFaultInjection
      if SnapshotReady and DirExists(ActiveRecoveryRoot) and
         (ExpandConstant('{param:TASK9MODE|}') = 'premarkercrash') then
      begin
        AtomicWriteText(RecoveryChild(ActiveRecoveryRoot, 'premarker-ready'), 'ready');
        for Index := 1 to 720 do Sleep(250);
      end;
#endif
  end
  else if CurStep = ssDone then
  begin
    if SnapshotReady and DirExists(ActiveRecoveryRoot) then
    begin
      if not RemoveObsoleteProductPayload(ActiveRecoveryRoot) then
      begin
        CommitFailed := True;
        CommitFailureExitCode := 75;
        exit;
      end;
      if not WriteCommittedMarker(ActiveRecoveryRoot) then
      begin
        CommitFailed := True;
        CommitFailureExitCode := 75;
        exit;
      end;
#ifdef AcceptanceFaultInjection
      if ExpandConstant('{param:TASK9MODE|}') = 'postmarkercrash' then
      begin
        AtomicWriteText(RecoveryChild(ActiveRecoveryRoot, 'postmarker-ready'), 'ready');
        for Index := 1 to 720 do Sleep(250);
      end;
#endif
      if not FinalizeIncomingTransaction(ActiveRecoveryRoot) then
      begin
        CommitFailed := True;
        CommitFailureExitCode := 76;
        exit;
      end;
    end;
    InstallationCompleted := True;
    if (not CommitFailed) and (LaunchAfterCommitCheckbox <> nil) and
       LaunchAfterCommitCheckbox.Checked and (not WizardSilent) then
      ExecAsOriginalUser(AddBackslash(AppRoot) + '{#ProductExe}', '', AppRoot,
        SW_SHOWNORMAL, ewNoWait, Index);
  end;
end;

function GetCustomSetupExitCode: Integer;
begin
  Result := CommitFailureExitCode;
end;

procedure InitializeWizard;
begin
  LaunchAfterCommitCheckbox := TNewCheckBox.Create(WizardForm);
  LaunchAfterCommitCheckbox.Parent := WizardForm.FinishedPage;
  LaunchAfterCommitCheckbox.Caption := 'Launch AmmarTrading Sync';
  LaunchAfterCommitCheckbox.Checked := True;
  LaunchAfterCommitCheckbox.Left := 0;
  LaunchAfterCommitCheckbox.Top := WizardForm.FinishedLabel.Top + WizardForm.FinishedLabel.Height + ScaleY(16);
  LaunchAfterCommitCheckbox.Width := WizardForm.FinishedPage.ClientWidth;
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
  Result := (ExpandConstant('{param:TASK9MODE|}') <> 'premarkercrash') and
            (ExpandConstant('{param:TASK9MODE|}') <> 'postmarkercrash');
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
  InsideUninstaller := True;
  UninstallUsesPriorProof := False;
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
  if DirExists(ActiveRecoveryRoot) then
  begin
    if (ClassifyActiveTransaction(ActiveRecoveryRoot) = AMMAR_TX_PRIOR) then
    begin
      if not ValidatePriorUninstallerProof(ActiveRecoveryRoot) then
      begin
        Log('ERROR: Uninstall blocked: run AmmarTrading Sync setup once to repair the ACTIVE transaction and verify prior uninstaller bytes.');
        exit;
      end;
      UninstallUsesPriorProof := True;
    end;
    if not ResolveActiveTransaction(ActiveRecoveryRoot) then
    begin
      Log('ERROR: Uninstall blocked by invalid durable recovery state; payload and registration were preserved.');
      exit;
    end;
  end;
  Log('Durable prior payload and incoming-only paths verified before uninstall.');
  Result := True;
end;
