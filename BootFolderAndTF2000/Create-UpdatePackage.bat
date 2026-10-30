@echo off
:: ============================================================================
::  BENCH SYSTEM - create TwinCAT update package on the USB stick.
::  Stops TwinCAT (ADS -> Config) + HMI Server, copies Boot + HMI folders to
::  <USB>:\TwinCAT_Update, then restarts them.
::  Optional arguments are passed to scripts\New-UpdatePackage.ps1, e.g.
::      Create-UpdatePackage.bat -Destination E:\
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

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\New-UpdatePackage.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo ==== Update package created successfully ====
) else (
    echo ==== FAILED - exit code %RC% - see messages above ====
)
if not defined NOPAUSE pause
exit /b %RC%
