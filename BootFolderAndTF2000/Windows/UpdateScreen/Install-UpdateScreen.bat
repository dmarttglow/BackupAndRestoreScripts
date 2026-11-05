@echo off
:: ============================================================================
::  MACHINE IPC (optional, run once) - install the update status screen.
::  Registers the scheduled task "TwinCAT Update Screen" that Apply-Update.bat
::  starts, so the full-screen "update in progress - do not power off" page
::  appears on the logged-on user's desktop. Apply-Update works without it.
::      Install-UpdateScreen.bat              install / update the task
::      Install-UpdateScreen.bat -Uninstall   remove it
:: ============================================================================
setlocal

net session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator rights...
    if "%~1"=="" (
        powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-UpdateScreen.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
if not defined NOPAUSE pause
exit /b %RC%
