@echo off
cd /d "%~dp0"
where py >nul 2>nul && (py remote_mouse.py --remove-startup) || (python remote_mouse.py --remove-startup)
pause
