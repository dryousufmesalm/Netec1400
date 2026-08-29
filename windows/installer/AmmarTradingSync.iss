#ifndef PublishDir
  #error PublishDir must be supplied by Build-AmmarTradingSync.ps1
#endif
#ifndef BootstrapperPath
  #error BootstrapperPath must be supplied by Build-AmmarTradingSync.ps1
#endif
#ifndef OutputDir
  #error OutputDir must be supplied by Build-AmmarTradingSync.ps1
#endif

#define ProductName "AmmarTrading Sync"
#define ProductVersion "1.0.0"
#define ProductPublisher "AmmarTrading"
#define ProductExe "AmmarTrading.Sync.exe"

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
OutputBaseFilename=AmmarTrading Sync Setup
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
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#BootstrapperPath}"; DestDir: "{tmp}"; DestName: "MicrosoftEdgeWebView2Setup.exe"; Flags: deleteafterinstall

[Icons]
Name: "{autoprograms}\AmmarTrading Sync"; Filename: "{app}\{#ProductExe}"; WorkingDir: "{app}"
Name: "{autodesktop}\AmmarTrading Sync"; Filename: "{app}\{#ProductExe}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{tmp}\MicrosoftEdgeWebView2Setup.exe"; Parameters: "/silent /install"; StatusMsg: "Installing Microsoft Edge WebView2 Runtime..."; Flags: waituntilterminated; Check: not IsWebView2Installed
Filename: "{app}\{#ProductExe}"; Description: "Launch AmmarTrading Sync"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
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
