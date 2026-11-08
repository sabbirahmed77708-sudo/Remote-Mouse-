@echo off
cd /d "%~dp0"
where py >nul 2>nul && (py remote_mouse.py) || (python remote_mouse.py)
pause
