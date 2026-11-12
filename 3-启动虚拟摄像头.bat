@echo off
chcp 936 >nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\start-vcam.ps1" 
echo.
pause