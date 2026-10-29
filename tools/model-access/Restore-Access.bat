@echo off
setlocal EnableExtensions DisableDelayedExpansion
title MiniPC - Restore Model Access
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" -Action Stop
set "accessExit=%errorlevel%"
echo.
pause
exit /b %accessExit%
