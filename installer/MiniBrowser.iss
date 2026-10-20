; Inno Setup script for MiniBrowser. Build with installer\build.ps1 (publishes first, then compiles this).
; Installs per user (no admin prompt) into %LOCALAPPDATA%\Programs\MiniBrowser.
; Browsing data (logins, cookies) lives in %LOCALAPPDATA%\MiniBrowser and is kept on uninstall.

#define AppName "MiniBrowser"
#define PublishDir "..\bin\installer-publish"
#define AppVersion GetVersionNumbersString(PublishDir + "\MiniBrowser.exe")

#if !FileExists(PublishDir + "\WebView2Loader.dll") || !FileExists(PublishDir + "\blocklist.txt") || !FileExists(PublishDir + "\Extensions\uBOLite\manifest.json")
  #error Publish output is incomplete - run installer\build.ps1 instead of compiling this script directly
#endif

[Setup]
AppId={{6F1C2B4E-8A3D-4E7B-9C51-2D8E7A1F04B3}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppName}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=Output
OutputBaseFilename=MiniBrowser-Setup-{#AppVersion}
SetupIconFile=..\Assets\logo.ico
UninstallDisplayIcon={app}\MiniBrowser.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Excludes: "*.xml,*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\MiniBrowser.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\MiniBrowser.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\MiniBrowser.exe"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[Code]
// The app is framework-dependent: it needs the .NET 10 Desktop Runtime (x64).
function HasDesktopRuntime10: Boolean;
var
  FindRec: TFindRec;
begin
  Result := FindFirst(ExpandConstant('{commonpf64}\dotnet\shared\Microsoft.WindowsDesktop.App\10.*'), FindRec);
  if Result then FindClose(FindRec);
end;

function InitializeSetup: Boolean;
var
  ErrorCode: Integer;
begin
  Result := True;
  if not HasDesktopRuntime10 then
    if MsgBox('MiniBrowser needs the .NET 10 Desktop Runtime (x64), which is not installed.' + #13#10 +
              'Open the download page now? Setup will continue either way.',
              mbConfirmation, MB_YESNO) = IDYES then
      ShellExec('open', 'https://dotnet.microsoft.com/download/dotnet/10.0', '', '', SW_SHOWNORMAL, ewNoWait, ErrorCode);
end;
