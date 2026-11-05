# TwinCAT Boot + HMI Server update scripts

| Where | Run | What it does |
|---|---|---|
| **Bench system** | `Create-UpdatePackage.bat` | Uses ADS to switch TwinCAT to Config mode and stops the HMI Server (`TcHmiSrv`). Copies the Boot folder and HMI Server folder to a local build folder with a SHA-256 manifest, restarts both, then zips the package to a single file, `<USB>:\TwinCAT_Update.zip`. |
| **Machine IPC** | `Apply-Update.bat` (started by the PLC) | Finds the zip on the USB stick, unzips it to a local staging folder and verifies it. Uses ADS to switch to Config mode and stops the HMI Server. Backs up the old version, replaces the folders, verifies them, rolls back if anything fails, then reboots. |

```
Apply-Update.bat / Create-UpdatePackage.bat   launchers
Config.ps1                                    paths, service name, options  <-- check this first
scripts\Common.ps1                            shared functions
scripts\New-UpdatePackage.ps1                 bench logic
scripts\Install-UpdatePackage.ps1             machine logic
UpdateScreen\                                 optional "update in progress" screen (see below)
```

## One-time setup

1. **Check the paths in `Config.ps1`** against a real IPC. The first folder that exists is used, and the log shows which one.
   - Boot: `C:\ProgramData\Beckhoff\TwinCAT\3.1\Boot` (4026) or `C:\TwinCAT\3.1\Boot` (4024)
   - HMI: `C:\ProgramData\Beckhoff\TF2000 TwinCAT 3 HMI Server` or `C:\TwinCAT\Functions\TF2000-HMI-Server\service`
2. **No extra software is needed for ADS.** The scripts use the .NET ADS API (`TwinCAT.Ads.dll`) that comes with TwinCAT 3. A self-contained v4.x copy is bundled next to `Config.ps1` and is tried first. If it doesn't work, they try the GAC, then search the TwinCAT install folders, preferring v4.x DLLs. On the machine, the DLL is found and connected before anything is stopped. If it can't be found, the update stops and nothing is changed. To check an IPC, especially a runtime-only (XAR) image:
   ```powershell
   Get-ChildItem 'C:\TwinCAT','C:\Program Files (x86)\Beckhoff' -Recurse -Filter TwinCAT.Ads.dll -EA 0 | Select FullName
   ```
3. **On each machine**, copy this whole folder to a fixed local path, for example `C:\TwinCAT_UpdateTool\`. The PLC needs a path that doesn't depend on the USB drive letter. The USB stick only needs to hold `TwinCAT_Update.zip`.

## PLC trigger (Tc2_Utilities `NT_StartProcess`)

```iecst
VAR
    fbStartUpdate : NT_StartProcess;
    bHmiUpdateButton : BOOL;   // linked to the HMI button
END_VAR

fbStartUpdate(
    NETID     := '',
    PATHSTR   := 'C:\Windows\System32\cmd.exe',
    DIRNAME   := 'C:\TwinCAT_UpdateTool',
    COMNDLINE := '/c C:\TwinCAT_UpdateTool\Apply-Update.bat',
    START     := bHmiUpdateButton,   // rising edge starts it
    TMOUT     := T#5S);
```

TwinCAT keeps running until the package has been fully validated. If the stick is missing or the package is bad, nothing is stopped and the machine keeps running. Once validation passes, the PLC and HMI go down and the IPC reboots about 10 s after the update finishes.

## Update status screen (optional)

On a machine with an HMI panel, `UpdateScreen\` puts up a full-screen kiosk page while Apply-Update runs. The page says the system is being updated, warns not to switch off the power or remove the USB stick, and shows live progress: a progress bar, the current step, file counts and elapsed time. At the end it shows the result: *Update complete* (with the reboot countdown), *Update not applied* (nothing changed), *previous version restored*, or *service needed* if the rollback failed.

```
UpdateScreen\Install-UpdateScreen.bat   run once per machine (admin): registers the scheduled task
UpdateScreen\Show-UpdateScreen.ps1      WPF kiosk window (borderless, topmost) hosting the page
UpdateScreen\UpdateScreen.html          the page itself: edit text/colours/logo here
```

**Setup:** after copying the tool to `C:\TwinCAT_UpdateTool\`, run `UpdateScreen\Install-UpdateScreen.bat` once. To remove it: `Install-UpdateScreen.bat -Uninstall`.

**Preview** without running an update (windowed, simulated progress). `-DemoResult` can be `Success`, `Failed`, `RolledBack` or `RollbackFailed`:
```
powershell -STA -ExecutionPolicy Bypass -File UpdateScreen\Show-UpdateScreen.ps1 -Demo -Windowed -DemoResult Success
```

**How it works**

- **The update never depends on the screen.** `Install-UpdatePackage.ps1` only writes its progress to `C:\TwinCAT_UpdateBackups\update_progress.json`, and any error writing that file is ignored. The screen only reads that file. If the screen is not installed, crashes or is closed, the update runs exactly the same.
- **Why a scheduled task:** the PLC starts Apply-Update as SYSTEM in session 0, where windows are invisible. So `Apply-Update.bat` doesn't open the screen itself. It runs `schtasks /Run /TN "TwinCAT Update Screen"` and ignores the result. The task runs as the local *Users* group, so it opens on the desktop of whoever is logged on (e.g. the HMI auto-logon user). With no one logged on, no screen appears and the update still runs.
- **Kiosk behaviour:** the window covers the HMI browser and can't be closed with Alt+F4 while the update runs. For maintenance, **Ctrl+Shift+F12** always closes it. A result without a reboot shows a *Close* button and closes by itself (20 s after success, 120 s after a failure). *Service needed* stays until someone closes it. During the reboot countdown there is no Close button.
- If no update starts within 90 s (e.g. the stick was missing and Apply-Update stopped before writing progress), the screen closes by itself. Errors from the screen are logged to `%TEMP%\TwinCAT_UpdateScreen.log` of the logged-on user.
- **Rendering:** the page is shown by the WPF `WebBrowser` control (the Internet Explorer 11 engine built into Windows), so nothing has to be installed. Keep any edits to `UpdateScreen.html` IE11-compatible (no CSS variables, no `let`/`const`/arrow functions).
- The logged-on user needs read access to `C:\TwinCAT_UpdateBackups` (the default permissions under `C:\` allow this).

## Optional arguments

Both launchers pass anything after them straight to their script, e.g. `Apply-Update.bat -NoReboot` or `Create-UpdatePackage.bat -Destination E:\`. The PLC trigger runs `Apply-Update.bat` with no arguments.

**`Apply-Update.bat` (machine)**

| Argument | What it does |
|---|---|
| `-AllowVersionMismatch` | Applies the package even if the XAR / TF2000 versions differ from this machine. The mismatch is still logged. Manual use only. |
| `-NoReboot` | Doesn't reboot at the end. Restarts the HMI Server and puts TwinCAT back into Run mode instead. |
| `-PackagePath <zip or folder>` | Uses this package zip (or the folder holding it) instead of searching all drives for `\TwinCAT_Update.zip`. Needed if more than one drive holds a package. An unzipped package folder from an older version of the scripts also works. |
| `-ConfigPath <file>` | Uses a different config file instead of `Config.ps1`. |

**`Create-UpdatePackage.bat` (bench)**

| Argument | What it does |
|---|---|
| `-Destination <drive or folder>` | Where to build the package, e.g. `E:\`. Default: the USB drive the script runs from, or the only USB drive present. |
| `-NoStop` | Copies without stopping TwinCAT / the HMI Server first. Not recommended: files can change mid-copy. |
| `-LeaveStopped` | Leaves TwinCAT in Config mode and the HMI Server stopped afterwards. |
| `-ConfigPath <file>` | Uses a different config file instead of `Config.ps1`. |

Set the environment variable `NOPAUSE=1` to stop `Create-UpdatePackage.bat` waiting for a keypress at the end (useful when calling it from another script).

## Result and logs (machine)

- `C:\TwinCAT_UpdateBackups\last_update_status.txt`: `SUCCESS` / `FAILED - nothing changed` / `FAILED - previous version restored` / `FAILED - ROLLBACK FAILED`
- `C:\TwinCAT_UpdateBackups\Logs\Apply_<time>.log`. A copy also goes to `<USB>:\TwinCAT_Update_Logs\`.
- `C:\TwinCAT_UpdateBackups\<time>_before_update\`: the old Boot and HMI folders. The last 5 are kept (`BackupsToKeep`).

Exit codes: 0 ok, 1 failed (nothing changed), 2 failed and rolled back, 3 rollback failed (the IPC is left in Config mode and **not** rebooted), 4 already running.

**Manual rollback** to an old version: copy `<time>_before_update\Boot` and `\HMI` back to their folders while TwinCAT is in Config mode and `TcHmiSrv` is stopped, then reboot. Or put that folder on a stick as `TwinCAT_Update`, set `"Purpose": "UpdatePackage"` in its `manifest.json`, and run Apply-Update. Each backup has its own `versions.json`, so the version check still applies.

## Important behaviour

- **PLC persistent data is kept.** `PreservePersistentData = $true` means `*.bootdata` files are neither packaged nor overwritten, so each machine keeps its own retained values. If the new PLC software changes persistent variables, check how TwinCAT handles that before you rely on it.
- **Mirror copy.** The target folders end up exactly like the package. Stale files are removed, except excluded files, which are left alone.
- **Version check (exact match).** The bench writes `versions.json` into the package. It records the TwinCAT XAR version (registry `TcVersion`, e.g. `3.1.4026.27`) and the TF2000 HMI Server version (ProductVersion of the exe the `TcHmiSrv` service runs, e.g. `25.0.122`). Apply-Update reads the same values on the machine. If either differs, or can't be read, it stops with an error **before anything is stopped or changed**, and both versions are written to the log. The bench refuses to build a package if it can't read either version. Running `Apply-Update.bat -AllowVersionMismatch` by hand overrides the check; the PLC trigger never does.
- **Hardware binding.** The Boot folder holds the bench's I/O configuration. EtherCAT adapters are bound to a MAC address or PCI slot, so the bench and machines should be the same IPC model and use the same adapter binding. Licences are not part of the Boot folder and don't move with it.
- **Zipped package.** The package is one file at the root of the stick, `TwinCAT_Update.zip` (Boot, HMI, `manifest.json`, `versions.json` inside). Next to it are the bench log `TwinCAT_Update_create.log` and, once a machine has run the update, the `TwinCAT_Update_Logs\` folder. The bench builds the package in `%TEMP%\TwinCAT_Update_build` and restarts TwinCAT and the HMI Server *before* zipping, so the downtime is only the copy. The machine unzips to `C:\TwinCAT_UpdateBackups\Staging`, checks every file's SHA-256 there, and deletes the staging folder at the end. Needs .NET Framework 4.5 or newer (part of every TwinCAT 3 install).
- Incomplete zips are written as `TwinCAT_Update.zip.partial` and are never picked up. The previous package on the stick is kept as `TwinCAT_Update_previous.zip` (and its log as `TwinCAT_Update_create_previous.log`). A `TwinCAT_Update` folder from an older version of the scripts is renamed to `TwinCAT_Update_old` the first time the new version builds a package (it can be deleted). Apply-Update still accepts packages in the older layouts.
