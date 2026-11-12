@echo off
chcp 936 >nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install-obs.ps1" 
echo.
pause