# Installs Remote Mouse Server on this PC.
#
# Why this exists: a file saved by a web browser carries a "downloaded from the internet" mark, and
# Windows then shows the blue/red "Windows protected your PC" (SmartScreen) page for programs that have
# no paid publisher certificate. A file downloaded by this script has no such mark.
# The installer itself still asks Windows for permission once (that is normal).
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url  = 'https://github.com/sabbirahmed77708-sudo/remote-mouse-/releases/latest/download/Remote-Mouse-Setup.exe'
$file = Join-Path $env:TEMP 'Remote-Mouse-Setup.exe'

Write-Host 'Downloading Remote Mouse (about 26 MB)...'
Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing
$hash = (Get-FileHash $file -Algorithm SHA256).Hash
Write-Host "SHA-256: $hash"
Write-Host 'Starting the installer. Press Yes when Windows asks for permission.'
Start-Process -FilePath $file -Wait
Write-Host 'Done. Open the Remote Mouse app on your phone and tap this PC.'
