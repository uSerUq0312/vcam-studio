@echo off
chcp 65001 >nul
cd /d "%~dp0"
set PY=pythonw
where pythonw >nul 2>&1 || set PY=D:\dev\Python313\pythonw.exe
start "" "%PY%" "%~dp0VcamStudio.py"
