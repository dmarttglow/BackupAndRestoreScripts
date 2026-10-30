# BackupAndRestoreScripts

Scripts for backing up, moving and restoring software on Beckhoff TwinCAT 3 IPCs. Each tool has its own folder, and each folder's README covers setup and details.

| Folder | What it's for |
|---|---|
| [`BootFolderAndTF2000`](BootFolderAndTF2000/README.md) | Copies the TwinCAT Boot folder (PLC + I/O config) and the TF2000 HMI Server data from a bench system to machine IPCs on a USB stick, with automatic backup and rollback. |

## BootFolderAndTF2000 in short

You build the software on a **bench system**, then put it on each **machine IPC** with a USB stick. No engineering laptop or TwinCAT XAE is needed at the machine.

1. **On the bench:** plug in a USB stick and run `Create-UpdatePackage.bat`. It briefly stops TwinCAT and the HMI Server and copies the Boot and HMI folders to `<USB>:\TwinCAT_Update`. It also saves a checksum for every file and records the TwinCAT / TF2000 versions, then starts TwinCAT and the HMI Server again.
2. **At the machine:** plug in the stick and press the update button on the HMI. The PLC runs `Apply-Update.bat`, which:
   - checks the package is complete and that the TwinCAT / TF2000 versions match this machine (if anything is wrong, it stops and changes nothing)
   - stops TwinCAT and the HMI Server, backs up the current version, and copies in the new one
   - checks every file, restores the backup automatically if anything fails, then reboots
3. **Check the result** in `C:\TwinCAT_UpdateBackups\last_update_status.txt` on the machine, or in the log copied back to the stick under `TwinCAT_Update\Logs\`.

Before the first use, check the paths in `BootFolderAndTF2000\Config.ps1`. Then copy the folder to a fixed local path on each machine (e.g. `C:\TwinCAT_UpdateTool\`). [BootFolderAndTF2000/README.md](BootFolderAndTF2000/README.md) covers the full setup, the PLC trigger code, optional arguments, logs and manual rollback.

## Requirements

- Windows IPCs with TwinCAT 3 installed. The scripts use the ADS DLL that comes with TwinCAT, so you don't need to install anything extra.
- Windows PowerShell 3.0 or newer (built into Windows). The scripts need administrator rights. When the PLC starts them, they run as SYSTEM.
- The bench system and the machines should be the same IPC model, with the same TwinCAT and TF2000 versions.
