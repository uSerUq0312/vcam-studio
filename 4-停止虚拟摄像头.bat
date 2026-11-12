@echo off
chcp 936 >nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\stop-vcam.ps1" 
echo.
pause