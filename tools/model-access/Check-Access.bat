@echo off
setlocal EnableExtensions DisableDelayedExpansion
title MiniPC - Check Model Access
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" -Action Status
set "accessExit=%errorlevel%"
echo.
pause
exit /b %accessExit%
