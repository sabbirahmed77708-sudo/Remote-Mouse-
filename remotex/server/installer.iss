; Inno Setup script: builds RemoteX-Server-Setup.exe from dist\RemoteXServer.exe
#define AppName "RemoteX Server"
#define AppVersion GetEnv("RX_VERSION")
#if AppVersion == ""
  #define AppVersion "1.1.0"
#endif

[Setup]
AppId={{6F1C2B8E-4D0A-4E57-9B3A-52E1D7A4C0F1}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=RemoteX
DefaultDirName={autopf}\RemoteX Server
DefaultGroupName=RemoteX
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename=RemoteX-Server-Setup
SetupIconFile=assets\icon.ico
UninstallDisplayIcon={app}\RemoteXServer.exe
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"
Name: "autostart"; Description: "Start RemoteX Server when Windows starts"; GroupDescription: "Options:"

[Files]
Source: "dist\RemoteXServer.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\RemoteX Server"; Filename: "{app}\RemoteXServer.exe"
Name: "{autodesktop}\RemoteX Server"; Filename: "{app}\RemoteXServer.exe"; Tasks: desktopicon
Name: "{userstartup}\RemoteX Server"; Filename: "{app}\RemoteXServer.exe"; Parameters: "--minimized"; Tasks: autostart

[Run]
; let the phone reach the PC on private (home) networks without the Windows Firewall question
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""RemoteX Server"" dir=in action=allow program=""{app}\RemoteXServer.exe"" profile=private enable=yes"; Flags: runhidden
Filename: "{app}\RemoteXServer.exe"; Description: "Start RemoteX Server now"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""RemoteX Server"""; Flags: runhidden; RunOnceId: "DelFirewallRule"
