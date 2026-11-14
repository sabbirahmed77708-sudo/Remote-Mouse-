; Builds dist\Remote-Mouse-Setup.exe from dist\RemoteXServer.exe.   iscc /DAppVersion=1.7.2 installer.iss
#ifndef AppVersion
  #define AppVersion "1.7.2"
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
Source: "register-task.ps1"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; the shortcuts start the program through its scheduled task, which runs with administrator rights (no question asked)
Name: "{autoprograms}\Remote Mouse"; Filename: "{sys}\schtasks.exe"; Parameters: "/Run /TN ""Remote Mouse Server (open)"""; IconFilename: "{app}\RemoteXServer.exe"; Flags: runminimized
Name: "{autodesktop}\Remote Mouse"; Filename: "{sys}\schtasks.exe"; Parameters: "/Run /TN ""Remote Mouse Server (open)"""; IconFilename: "{app}\RemoteXServer.exe"; Flags: runminimized; Tasks: desktopicon

[InstallDelete]
; shortcuts of the earlier "RemoteX Server" installs
Type: files; Name: "{autodesktop}\RemoteX Server.lnk"
Type: files; Name: "{autoprograms}\RemoteX Server.lnk"
Type: files; Name: "{userstartup}\RemoteX Server.lnk"
Type: files; Name: "{commonstartup}\RemoteX Server.lnk"
; the start-up shortcut of version 1.6 and earlier (a scheduled task does that job now)
Type: files; Name: "{commonstartup}\Remote Mouse.lnk"

[Run]
; let the phone reach the PC on home/work (Private) networks without a Firewall question
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Remote Mouse Server"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Remote Mouse Server"" dir=in action=allow program=""{app}\RemoteXServer.exe"" profile=private enable=yes"; Flags: runhidden
; the scheduled tasks that start the program with administrator rights (optionally at sign-in)
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\register-task.ps1"" -Exe ""{app}\RemoteXServer.exe"" -AtLogon {code:AtLogonFlag}"; Flags: runhidden waituntilterminated
Filename: "{sys}\schtasks.exe"; Parameters: "/Run /TN ""Remote Mouse Server"""; Description: "Start Remote Mouse now (it runs quietly in the background)"; Flags: nowait postinstall skipifsilent
; after an automatic update the program starts again by itself
Filename: "{sys}\schtasks.exe"; Parameters: "/Run /TN ""Remote Mouse Server"""; Flags: nowait runhidden; Check: RestartRequested

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\register-task.ps1"" -Remove"; Flags: runhidden waituntilterminated; RunOnceId: "DelTasks"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Remote Mouse Server"""; Flags: runhidden; RunOnceId: "DelFirewallRule"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM RemoteXServer.exe"; Flags: runhidden; RunOnceId: "KillApp"

[Code]
function AtLogonFlag(Param: String): String;
begin
  if WizardIsTaskSelected('startup') then Result := '1' else Result := '0';
end;

function RestartRequested: Boolean;
begin
  Result := ExpandConstant('{param:RESTARTAPP|0}') = '1';
end;
