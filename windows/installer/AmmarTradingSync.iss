#ifndef PublishDir
  #error PublishDir must be supplied by Build-AmmarTradingSync.ps1
#endif
#ifndef BootstrapperPath
  #error BootstrapperPath must be supplied by Build-AmmarTradingSync.ps1
#endif
#ifndef OutputDir
  #error OutputDir must be supplied by Build-AmmarTradingSync.ps1
#endif
#ifdef AcceptanceFaultInjection
  #ifndef FaultProbePath
    #error FaultProbePath must be supplied for the acceptance-only fault installer
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
Source: "{#PublishDir}\AmmarTrading.Sync.payload-manifest.txt"; DestDir: "{tmp}"; DestName: "IncomingPayloadManifest.txt"; Flags: deleteafterinstall; AfterInstall: SnapshotProductPayload
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#BootstrapperPath}"; DestDir: "{tmp}"; DestName: "MicrosoftEdgeWebView2Setup.exe"; Flags: deleteafterinstall
#ifdef AcceptanceFaultInjection
Source: "{#FaultProbePath}"; DestDir: "{app}"; DestName: "{#ProductExe}"; Flags: ignoreversion
Source: "{#FaultProbePath}"; DestDir: "{app}"; DestName: "AmmarTrading.Sync.Core.dll"; Flags: ignoreversion
Source: "{#FaultProbePath}"; DestDir: "{app}\Assets\Web"; DestName: "index.html"; Flags: ignoreversion
Source: "{#FaultProbePath}"; DestDir: "{app}\Scripts"; DestName: "Sync-BasketsToOneDrive.ps1"; Flags: ignoreversion
Source: "{#FaultProbePath}"; DestDir: "{app}"; DestName: "Task9FaultProbe.applied"; Flags: ignoreversion
Source: "{#FaultProbePath}"; DestDir: "{app}"; DestName: "Task9UpgradeFault.blocked"; Flags: ignoreversion
#endif

[Icons]
Name: "{autoprograms}\AmmarTrading Sync"; Filename: "{app}\{#ProductExe}"; WorkingDir: "{app}"
Name: "{autodesktop}\AmmarTrading Sync"; Filename: "{app}\{#ProductExe}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{tmp}\MicrosoftEdgeWebView2Setup.exe"; Parameters: "/silent /install"; StatusMsg: "Installing Microsoft Edge WebView2 Runtime..."; Flags: waituntilterminated; Check: not IsWebView2Installed
Filename: "{app}\{#ProductExe}"; Description: "Launch AmmarTrading Sync"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
const
  AMMAR_INVALID_FILE_ATTRIBUTES = $FFFFFFFF;

var
  RollbackRoot: String;
  RollbackStatePath: String;
  SnapshotReady: Boolean;
  InstallationCompleted: Boolean;

function GetFileAttributesW(lpFileName: String): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall';

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
  AppRoot, Cursor, Parent: String;
  Attributes: Cardinal;
begin
  Result := False;
  if not IsSafeRelativePayloadPath(RelativePath) then
    exit;

  AppRoot := ExpandConstant('{app}');
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

procedure SnapshotProductPayload;
var
  PayloadPaths, StateLines: TArrayOfString;
  Index: Integer;
  RelativePath, InstalledPath, BackupPath: String;
begin
  SetArrayLength(PayloadPaths, 0);
  AddManifestPayloadPaths(ExpandConstant('{app}\AmmarTrading.Sync.payload-manifest.txt'), PayloadPaths, False);
  AddManifestPayloadPaths(ExpandConstant('{tmp}\IncomingPayloadManifest.txt'), PayloadPaths, True);
  if GetArrayLength(PayloadPaths) = 0 then
    RaiseException('The product payload manifest is empty.');

  RollbackRoot := ExpandConstant('{tmp}\AmmarTrading.Sync.rollback');
  RollbackStatePath := ExpandConstant('{tmp}\AmmarTrading.Sync.rollback-state');
  SetArrayLength(StateLines, GetArrayLength(PayloadPaths));
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
      BackupPath := AddBackslash(RollbackRoot) + RelativePath;
      if not ForceDirectories(ExtractFileDir(BackupPath)) then
        RaiseException('Setup could not create the product rollback directory.');
      if not FileCopy(InstalledPath, BackupPath, False) then
        RaiseException('Setup could not snapshot the existing product payload. The installation was not changed.');
      StateLines[Index] := 'E|' + RelativePath;
    end
    else
      StateLines[Index] := 'M|' + RelativePath;
  end;
  if not SaveStringsToFile(RollbackStatePath, StateLines, False) then
    RaiseException('Setup could not persist the product rollback state. The installation was not changed.');
  SnapshotReady := True;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  InstallationCompleted := False;
  SnapshotReady := False;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssDone then
    InstallationCompleted := True;
end;

procedure DeinitializeSetup;
var
  StateLines: TArrayOfString;
  Index: Integer;
  StateLine, RelativePath, InstalledPath, BackupPath: String;
begin
  if InstallationCompleted or (not SnapshotReady) then
    exit;

  if not LoadStringsFromFile(RollbackStatePath, StateLines) then
  begin
    Log('ERROR: Rollback could not read the product payload state.');
    exit;
  end;
  for Index := 0 to GetArrayLength(StateLines) - 1 do
  begin
    StateLine := StateLines[Index];
    if (Length(StateLine) < 3) or (StateLine[2] <> '|') then
    begin
      Log('ERROR: Rollback refused a malformed product payload state entry.');
      continue;
    end;
    RelativePath := Copy(StateLine, 3, Length(StateLine) - 2);
    if not IsContainedNonReparsePayloadPath(RelativePath) then
    begin
      Log('ERROR: Rollback refused an unsafe or reparse-point payload path.');
      continue;
    end;
    InstalledPath := AddBackslash(ExpandConstant('{app}')) + RelativePath;
    if StateLine[1] = 'E' then
    begin
      BackupPath := AddBackslash(RollbackRoot) + RelativePath;
      if FileExists(InstalledPath) and (not DeleteFile(InstalledPath)) then
        Log('ERROR: Rollback could not remove a failed product payload file.');
      if not FileCopy(BackupPath, InstalledPath, False) then
        Log('ERROR: Rollback could not restore an existing product payload file.');
    end
    else if StateLine[1] = 'M' then
    begin
      if FileExists(InstalledPath) and (not DeleteFile(InstalledPath)) then
        Log('ERROR: Rollback could not remove a newly introduced product payload file.');
    end
    else
      Log('ERROR: Rollback refused an unknown product payload state action.');
  end;
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
