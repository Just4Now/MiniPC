@echo off
setlocal EnableExtensions DisableDelayedExpansion
title MiniPC - Enable Model Access
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" -Action Start
set "accessExit=%errorlevel%"
echo.
pause
exit /b %accessExit%
