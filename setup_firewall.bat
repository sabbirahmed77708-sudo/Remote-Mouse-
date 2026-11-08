@echo off
rem Run this ONCE as administrator (right-click -> Run as administrator).
rem It lets your phone reach Remote Mouse on the home Wi-Fi (Private networks only).
net session >nul 2>nul
if errorlevel 1 (
  echo Please right-click this file and choose "Run as administrator".
  pause
  exit /b 1
)
netsh advfirewall firewall delete rule name="Remote Mouse" >nul 2>nul
netsh advfirewall firewall add rule name="Remote Mouse" dir=in action=allow protocol=TCP localport=8765 profile=private
echo.
echo Done. If your phone still cannot connect, set your Wi-Fi to the "Private" profile:
echo Settings - Network and Internet - Wi-Fi - your network - Network profile type - Private.
pause
