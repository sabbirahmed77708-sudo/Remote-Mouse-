@echo off
cd /d "%~dp0"
where py >nul 2>nul && (py remote_mouse.py --install-startup) || (python remote_mouse.py --install-startup)
echo.
echo Remote Mouse will now start by itself (hidden) whenever you sign in to Windows.
pause
