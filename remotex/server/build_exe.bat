@echo off
rem Builds dist\RemoteXServer.exe (one file, no console window).
rem Needs Python 3.10+ on PATH.
cd /d "%~dp0"
python -m pip install --upgrade pip
python -m pip install -r requirements.txt pyinstaller || goto :error
python -m PyInstaller --noconfirm --clean --onefile --noconsole ^
  --name RemoteXServer ^
  --icon assets\icon.ico ^
  --add-data "assets\icon.ico;assets" ^
  --collect-submodules websockets ^
  --hidden-import pystray._win32 ^
  --hidden-import PIL.ImageGrab ^
  --hidden-import PIL.ImageDraw ^
  run_server.py || goto :error
echo.
echo Built: %~dp0dist\RemoteXServer.exe
if not defined CI pause
exit /b 0
:error
echo Build failed.
if not defined CI pause
exit /b 1
