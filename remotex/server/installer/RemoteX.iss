; Builds RemoteX-Setup.exe. Needs Inno Setup 6:  iscc /DAppVersion=1.1.0 installer\RemoteX.iss
#ifndef AppVersion
  #define AppVersion "1.2.0"
#endif

[Setup]
AppId={{6B0F7A4E-2C1D-4F8B-9A53-52656D6F7465}
AppName=RemoteX Server
AppVersion={#AppVersion}
AppPublisher=RemoteX
DefaultDirName={autopf}\RemoteX Server
DefaultGroupName=RemoteX
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=RemoteX-Setup
SetupIconFile=..\assets\icon.ico
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
Name: "startup"; Description: "Start RemoteX Server when Windows starts (minimized)"; GroupDescription: "Options:"

[Files]
Source: "..\dist\RemoteXServer.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\RemoteX\RemoteX Server"; Filename: "{app}\RemoteXServer.exe"
Name: "{autoprograms}\RemoteX\Uninstall RemoteX Server"; Filename: "{uninstallexe}"
Name: "{autodesktop}\RemoteX Server"; Filename: "{app}\RemoteXServer.exe"; Tasks: desktopicon
Name: "{commonstartup}\RemoteX Server"; Filename: "{app}\RemoteXServer.exe"; Tasks: startup

[Run]
; let the phone reach the PC on home/work (Private) networks without a Firewall question
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""RemoteX Server"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""RemoteX Server"" dir=in action=allow program=""{app}\RemoteXServer.exe"" profile=private enable=yes"; Flags: runhidden
Filename: "{app}\RemoteXServer.exe"; Description: "Start RemoteX Server now (it runs quietly in the background)"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""RemoteX Server"""; Flags: runhidden; RunOnceId: "DelFirewall"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM RemoteXServer.exe"; Flags: runhidden; RunOnceId: "KillApp"
