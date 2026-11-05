@echo off
:: ============================================================================
::  MACHINE IPC - apply the TwinCAT update package from the USB stick.
::  Unattended: intended to be started by the PLC (NT_StartProcess) from an
::  HMI button. Validates the package, stops TwinCAT (ADS -> Config) + HMI
::  Server, backs up the old version, replaces Boot + HMI folders, verifies,
::  rolls back on failure, then reboots.
::
::  Result: C:\TwinCAT_UpdateBackups\last_update_status.txt
::  Exit codes: 0 ok, 1 failed (nothing changed), 2 failed (rolled back),
::              3 failed + rollback failed, 4 already running
:: ============================================================================
setlocal

:: When started by the PLC this runs as SYSTEM (already elevated).
:: When double-clicked by a user, elevate first.
net session >nul 2>&1
if errorlevel 1 (
    if "%~1"=="" (
        powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)

:: Optional status screen (UpdateScreen\Install-UpdateScreen.bat). If the task is
:: not installed this does nothing, and the update never waits for or needs it.
schtasks.exe /Run /TN "TwinCAT Update Screen" >nul 2>&1

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0scripts\Install-UpdatePackage.ps1" %*
exit /b %ERRORLEVEL%
