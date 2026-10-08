; MeetingQ Inno Setup Script
; Requires: Inno Setup 6.x
; Build: dotnet publish -c Release   (self-contained single-file exe, runtime bundled)
;        then run this script to produce the installer

#define AppName      "MeetingQ"
#define AppVersion   "1.0.0"
#define AppPublisher "MeetingQ"
#define AppExeName   "MeetingQ.exe"
#define AppId        "{{A3F2E1D0-9B4C-4E5A-8F7D-6C2B1A0E9F3D}"

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL=https://github.com/
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
AllowNoIcons=yes
OutputDir=..\dist
OutputBaseFilename=MeetingQ-Setup-{#AppVersion}
; SetupIconFile=..\src\MeetingQ\Resources\app.ico  ; add app.ico to enable custom icon
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64
MinVersion=10.0.17763
UninstallDisplayIcon={app}\{#AppExeName}
CloseApplications=yes

; Self-contained build bundles the .NET 8 runtime — no prerequisite check needed.

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务"; Flags: unchecked
Name: "startuprun";  Description: "开机时自动启动 MeetingQ"; GroupDescription: "附加任务"; Flags: unchecked

[Files]
Source: "..\src\MeetingQ\bin\Release\net8.0-windows10.0.17763.0\win-x64\publish\*"; \
    DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}";          Filename: "{app}\{#AppExeName}"
Name: "{group}\卸载 {#AppName}";     Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}";    Filename: "{app}\{#AppExeName}"; Tasks: desktopicon
Name: "{userstartup}\{#AppName}";    Filename: "{app}\{#AppExeName}"; Tasks: startuprun

[Run]
Filename: "{app}\{#AppExeName}"; Description: "启动 MeetingQ"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Remove user data only if user confirms (via custom page — kept simple here)
Type: dirifempty; Name: "{app}"
