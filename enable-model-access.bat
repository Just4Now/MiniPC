@echo off
setlocal EnableExtensions DisableDelayedExpansion
title MiniPC - Enable Model Access
set "MINIPC_ACCESS_ROOT=%~dp0"
set "MINIPC_ACCESS_FAILED=0"

if not exist "%~dp0scripts\vl-app-access.ps1" goto missing_script

:menu
echo.
echo MiniPC - Enable access for VL and Qwen3.5
echo.
echo   1. MateBook Pro S
echo   2. MateBook Pro
echo   3. Both computers
echo   4. Enter another device ID
echo   0. Exit
echo.
echo Requires a connected device with an existing root HDC session.
echo The compute application will be restarted.
echo Model weights and compatible runtime libraries must already be installed.
echo.
choice /C 12340 /N /M "Select [1/2/3/4/0]: "
if errorlevel 255 goto input_error
if errorlevel 5 exit /b 0
if errorlevel 4 goto custom
if errorlevel 3 goto both
if errorlevel 2 goto pro
if errorlevel 1 goto pros
exit /b 0

:pros
set "MINIPC_ACCESS_DEVICE=7QB0126509000160"
call :enable
goto finish

:pro
set "MINIPC_ACCESS_DEVICE=3QC0124C20000251"
call :enable
goto finish

:both
set "MINIPC_ACCESS_DEVICE=7QB0126509000160"
call :enable
set "MINIPC_ACCESS_DEVICE=3QC0124C20000251"
call :enable
goto finish

:custom
set "MINIPC_ACCESS_DEVICE="
set /P "MINIPC_ACCESS_DEVICE=Device ID: "
if not defined MINIPC_ACCESS_DEVICE goto menu
call :enable
goto finish

:enable
echo.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "try { Write-Host ('Configuring device: ' + $env:MINIPC_ACCESS_DEVICE); & (Join-Path $env:MINIPC_ACCESS_ROOT 'scripts\vl-app-access.ps1') -Device $env:MINIPC_ACCESS_DEVICE -Action Start -RestartApp; exit 0 } catch { Write-Host $_ -ForegroundColor Red; exit 1 }"
if errorlevel 1 (
  set "MINIPC_ACCESS_FAILED=1"
  echo ERROR: Access setup failed. See the message above.
  exit /b 1
)
echo Access enabled and compute application restarted.
exit /b 0

:missing_script
echo ERROR: scripts\vl-app-access.ps1 is missing. Keep this BAT in the project root.
set "MINIPC_ACCESS_FAILED=1"
goto finish

:input_error
echo ERROR: Unable to read the selection.
set "MINIPC_ACCESS_FAILED=1"

:finish
echo.
if "%MINIPC_ACCESS_FAILED%"=="0" echo Done. Select an installed model in the application settings.
if "%MINIPC_ACCESS_FAILED%"=="1" echo One or more devices could not be configured.
echo Run this BAT again after rebooting the target device.
echo.
pause
exit /b %MINIPC_ACCESS_FAILED%
