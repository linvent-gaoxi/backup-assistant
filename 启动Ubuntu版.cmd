@echo off
cd /d "%~dp0"
wsl.exe -d Ubuntu -- bash linux/start.sh
pause
