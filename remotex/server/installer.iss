; Builds dist\Remote-Mouse-Setup.exe from dist\RemoteXServer.exe.   iscc /DAppVersion=1.4.0 installer.iss
#ifndef AppVersion
  #define AppVersion "1.4.0"
#endif

[Setup]
AppId={{6F1C2B8E-4D0A-4E57-9B3A-52E1D7A4C0F1}
AppName=Remote Mouse Server
AppVersion={#AppVersion}
AppPublisher=Remote Mouse
DefaultDirName={autopf}\Remote Mouse
DefaultGroupName=Remote Mouse
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename=Remote-Mouse-Setup
SetupIconFile=assets\icon.ico
UninstallDisplayIcon={app}\RemoteXServer.exe
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"
Name: "startup"; Description: "Start Remote Mouse when Windows starts"; GroupDescription: "Options:"

[Files]
Source: "dist\RemoteXServer.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Remote Mouse"; Filename: "{app}\RemoteXServer.exe"
Name: "{autodesktop}\Remote Mouse"; Filename: "{app}\RemoteXServer.exe"; Tasks: desktopicon
Name: "{commonstartup}\Remote Mouse"; Filename: "{app}\RemoteXServer.exe"; Parameters: "--minimized"; Tasks: startup

[InstallDelete]
; shortcuts of the earlier "RemoteX Server" installs
Type: files; Name: "{autodesktop}\RemoteX Server.lnk"
Type: files; Name: "{autoprograms}\RemoteX Server.lnk"
Type: files; Name: "{userstartup}\RemoteX Server.lnk"
Type: files; Name: "{commonstartup}\RemoteX Server.lnk"

[Run]
; let the phone reach the PC on home/work (Private) networks without a Firewall question
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Remote Mouse Server"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Remote Mouse Server"" dir=in action=allow program=""{app}\RemoteXServer.exe"" profile=private enable=yes"; Flags: runhidden
Filename: "{app}\RemoteXServer.exe"; Description: "Start Remote Mouse now (it runs quietly in the background)"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Remote Mouse Server"""; Flags: runhidden; RunOnceId: "DelFirewallRule"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM RemoteXServer.exe"; Flags: runhidden; RunOnceId: "KillApp"
