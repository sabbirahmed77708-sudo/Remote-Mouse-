@echo off
rem Runs the server from source (needs Python 3.10+ and: pip install -r requirements.txt)
cd /d "%~dp0"
where py >nul 2>nul && (py -m remotex_server) || (python -m remotex_server)
if errorlevel 1 pause
