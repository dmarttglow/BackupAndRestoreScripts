<#
.SYNOPSIS
    MACHINE IPC (optional, run once as Administrator): registers the scheduled task
    that shows the update status screen on the logged-on user's desktop.

.DESCRIPTION
    Apply-Update runs as SYSTEM when the PLC starts it, in session 0, where no
    window can be seen. Apply-Update.bat therefore does not open the screen itself:
    it runs "schtasks /Run /TN "TwinCAT Update Screen"" and ignores the result.
    This task runs Show-UpdateScreen.ps1 in the session of the user who is logged on
    (any member of the local Users group, e.g. the HMI auto-logon user). That switches
    the TF1200 UI Client running there to the status page (or, if no UI Client is
    running, opens a full-screen PowerShell window instead).

    If the task is not installed, Apply-Update works exactly the same, just
    without the screen.

.PARAMETER Uninstall
    Remove the task.

.PARAMETER IfMissing
    Used by Apply-Update.bat: install the task only if it does not exist yet, and only if
    this tool is on a fixed local disk (a task pointing at a USB stick stops working as
    soon as the stick is removed). Does nothing otherwise.
#>
[CmdletBinding()]
param([switch]$Uninstall, [switch]$IfMissing)

$ErrorActionPreference = 'Stop'
$TaskName = 'TwinCAT Update Screen'

if ($Uninstall) {
    & schtasks.exe /Delete /TN $TaskName /F
    if ($LASTEXITCODE -ne 0) { throw "Could not remove the task '$TaskName' (exit code $LASTEXITCODE)." }
    Write-Host "Task '$TaskName' removed."
    exit 0
}

$script = Join-Path $PSScriptRoot 'Show-UpdateScreen.ps1'
if (-not (Test-Path -LiteralPath $script)) { throw "Not found: $script" }
$onLocalDisk = $script -match '^[A-Za-z]:\\' -and (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($script))).DriveType -eq 'Fixed'
if ($IfMissing) {
    # Through cmd /c: schtasks writes "not found" to stderr, which would be a terminating error here.
    & cmd.exe /c "schtasks.exe /Query /TN `"$TaskName`" >nul 2>&1"
    if ($LASTEXITCODE -eq 0) { Write-Host "Task '$TaskName' already installed."; exit 0 }
    if (-not $onLocalDisk) { Write-Warning "Not installing the task: the tool is not on a local disk ($script)."; exit 0 }
}
if (-not $onLocalDisk) {
    Write-Warning "The screen script is not on a local disk ($script). Copy the tool to a fixed local path (e.g. C:\TwinCAT_UpdateTool) and run this again from there."
}

$esc = { param($s) [Security.SecurityElement]::Escape($s) }
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""

# Principal: the local Users group (S-1-5-32-545), so the task runs in the
# desktop session of whoever is logged on, without needing their password.
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Shows the TwinCAT update status screen in the TF1200 UI Client (started by Apply-Update.bat). Optional: the update works without it.</Description>
  </RegistrationInfo>
  <Triggers />
  <Principals>
    <Principal id="Users">
      <GroupId>S-1-5-32-545</GroupId>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT4H</ExecutionTimeLimit>
    <Priority>4</Priority>
  </Settings>
  <Actions Context="Users">
    <Exec>
      <Command>$(& $esc $psExe)</Command>
      <Arguments>$(& $esc $arguments)</Arguments>
      <WorkingDirectory>$(& $esc $PSScriptRoot)</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

$tmp = Join-Path $env:TEMP 'TwinCAT_UpdateScreen_task.xml'
[IO.File]::WriteAllText($tmp, $xml, [Text.Encoding]::Unicode)
try {
    & schtasks.exe /Create /TN $TaskName /XML $tmp /F
    if ($LASTEXITCODE -ne 0) { throw "schtasks /Create failed (exit code $LASTEXITCODE)." }
} finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host "Task '$TaskName' installed. It runs: $script"
Write-Host 'Preview without an update (simulated progress, goes back to the HMI page after about 45 s):'
Write-Host "    powershell -STA -ExecutionPolicy Bypass -File `"$script`" -Demo"
Write-Host 'The same in the PowerShell window instead of the TF1200 UI Client:'
Write-Host "    powershell -STA -ExecutionPolicy Bypass -File `"$script`" -Demo -Mode Window -Windowed"
