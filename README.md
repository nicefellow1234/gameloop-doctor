# GameLoop Doctor

**All-in-one, detect-first Windows Desktop App & PowerShell tool** to remove buggy **GameLoop 7.0 ("Androws" / TenStore Android Connect)**, restore **Classic GameLoop (`TxGameAssistant`)** with sharp **Ultra HD 2K**, **permanently block forced 7.0 emulator upgrades while keeping game downloads & game updates working**, and fix common lag/stutter bottlenecks on any Windows 10 or 11 PC.

> **100% Anti-Cheat Safe & Detect-First:**
> - GameLoop Doctor only manages Windows host files, NTFS folder permissions, optional Firewall rules, and Windows GPU/DPI settings. It **never** touches internal game files (`UserCustom.ini`, `Active.sav`, `data.vhd`) or game memory.
> - **Never applies blind tweaks:** Automatically discovers your fixed NTFS drives, custom or standard GameLoop install paths (via Registry + Services + Drives), GPU vendor (NVIDIA / AMD / Intel discrete vs. integrated), Windows DPI scaling, and active antivirus before showing a preview of only the changes needed on *your* PC.
> - **Games Stay 100% Online:** Surgically blocks the GameLoop 7.0 emulator self-upgrade **without** blocking `AppMarket.exe` in the firewall, so downloading and updating PUBG Mobile, Call of Duty Mobile, Free Fire, and other games continues working automatically inside Classic GameLoop!

---

## Why This Tool Exists

If Classic GameLoop (`TxGameAssistant`) silently upgraded your PC to **GameLoop 7.0 ("Androws")**, you probably hit:
- **Blurry ~720p graphics** on *Smooth / Super Smooth* (GameLoop 7.0 removed Classic GameLoop's `Gaming Resolution: Ultra HD 2K` engine hook).
- **Random mouse camera freezes & missed keys** (GameLoop 7.0's Hyper-V HCS input pipe + raw touch resets + high polling-rate gaming mice).
- **Mid-game lag spikes** (Hyper-V contending with VMs/containers, Windows Memory Integrity / HVCI, dual-GPU compositing, DPI scaling, and real-time antivirus scanning of emulator virtual disks).
- **Repeated forced upgrades:** Even after reinstalling Classic GameLoop, bundled updaters (`AndrowsInstaller.exe`, `pcyyb_installer.exe`, `PcyybAssistant.exe`, `tupdate.exe`) and silently downloaded `com_tencent_gameloop_*.exe` installers force-install 7.0 again — even hopping to another drive if only one folder is blocked.

---

## Quick Start (3 Ways to Run — Zero Dependencies!)

Works out of the box on **any Windows 10 or Windows 11 PC** (no Python, Node, or .NET SDK install required):

### Option 1 — One-Line PowerShell Command (Fastest!)
Open **PowerShell** (or **Windows Terminal**) and run:
```powershell
irm https://raw.githubusercontent.com/<YOUR_GITHUB_USERNAME>/gameloop-doctor/main/GameLoop-Doctor.ps1 -OutFile "$env:TEMP\GameLoop-Doctor.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\GameLoop-Doctor.ps1"
```
*(Replace `<YOUR_GITHUB_USERNAME>` with your GitHub username after pushing.)*

### Option 2 — Double-Click Desktop App (From Cloned Repo / Release)
1. Download or clone this repository (or grab `GameLoop-Doctor.exe` from GitHub Releases).
2. Double-click **`Launch-GameLoop-Doctor.bat`** (or `GameLoop-Doctor.exe`).
3. Accept the standard Windows Administrator (UAC) prompt — the dark native desktop window opens and runs a read-only scan of your PC before changing anything.

### Option 3 — Headless CLI Commands & `-DryRun` Preview (Power Users)
```powershell
# Scan your PC without changing anything (no Admin needed)
.\GameLoop-Doctor.ps1 -Diagnose

# Preview what any action would change on THIS PC before applying (-DryRun)
.\GameLoop-Doctor.ps1 -RemoveGameLoop7 -DryRun
.\GameLoop-Doctor.ps1 -LockUpdates -DryRun
.\GameLoop-Doctor.ps1 -OptimizeWindows -DryRun

# Apply actions
.\GameLoop-Doctor.ps1 -RemoveGameLoop7    # Step 1: Detect & remove GameLoop 7.0
.\GameLoop-Doctor.ps1 -LockUpdates        # Step 2: Block 7.0 emulator upgrade ONLY (keeps game downloads/updates online!)
.\GameLoop-Doctor.ps1 -OptimizeWindows    # Apply hardware-appropriate GPU, DPI, DVR & Defender fixes
.\GameLoop-Doctor.ps1 -StrictBlockStore   # Optional: also block AppMarket.exe outbound in Firewall
.\GameLoop-Doctor.ps1 -AllowStore         # Re-allow AppMarket.exe outbound if Strict Mode was used
.\GameLoop-Doctor.ps1 -UnblockAll         # Reverse all blocks cleanly
```

---

## Recommended Step-by-Step Workflow

1. **Remove GameLoop 7.0:** Click **Remove GameLoop 7.0** — scans your PC via Services, Registry, and all fixed NTFS drives, shows every detected 7.0 component in a confirmation dialog, then removes `GameLoopService`, 7.0 folders, cached silent upgraders, and 7.0 registry entries *(without deleting your Classic `GLP_installer*.exe` or Classic GameLoop files)*.
2. **Install Classic GameLoop & Your Games:** Click **Launch Classic Installer**, install Classic GameLoop (`TxGameAssistant`), and download your games (PUBG Mobile, Call of Duty Mobile, Free Fire, etc.).
   - In Classic GameLoop **Settings → Game**, set **Gaming Resolution** to **Ultra HD 2K** (if supported by your monitor/GPU).
3. **Block Forced 7.0 Emulator Upgrades (While Keeping Game Downloads & Updates Online!):** Click **Lock Out 7.0 Updates (Games Online)**. Shows a preview first, then applies a **surgical shield** that stops ONLY the emulator upgrade without touching game downloads:
   - **Layer 1 (All-Drive NTFS Deny-Write Lockdown):** Automatically detects every fixed NTFS drive on your PC and creates empty write-denied `Program Files\Tencent\GameLoop` & `GameLoopData` placeholders plus `%APPDATA%\Tencent\GameLoop`, `%APPDATA%\Tencent\DeskUpdate`, and `%LOCALAPPDATA%\Tencent\GameLoop`. Even if an elevated 7.0 silent installer runs, Windows NTFS rejects every write and it exits immediately with zero impact on Classic GameLoop.
   - **Layer 2 (Surgical Bundled & Silent Upgrader Neutralizer):**
     - Disables Classic's bundled 7.0/emulator updater binaries (`AppMarket\AndrowsInstaller.exe`, `UI\pcyyb_installer.exe`, `AppMarket\PcyybAssistant.exe`, `AppMarket\GF186\tupdate.exe`, `AppMarket\Update.exe`, `UI\Update.exe`) — **without touching `AppMarket.exe`, `GameDownload.exe`, or game engines!**
     - Neutralizes any cached `com_tencent_gameloop_*.exe` silent upgraders into 0-byte write+execute-denied stubs so they can't be re-downloaded or executed.
     - Sets Classic `AutoUpdate = 0` and `EnableAutoUpdate = 0`.
   - **Layer 3 (Direct Launcher Shortcut & Online Store):** Creates a **`GameLoop Classic (Direct Launch)`** shortcut on your Desktop (`AndroidEmulatorEn.exe -vm 100`) for one-click play, while keeping `AppMarket.exe` **100% online** so installing new games and major seasonal APK updates work automatically!
   - *(Optional Strict Mode)* If you ever want to block `AppMarket.exe` outbound network traffic too, use **Optional: Strict Block Store** (protected by Smart Download Guard so it won't block before your emulator engine is installed).
4. **Apply Detected Performance Fixes:** Click **Apply Detected Performance Fixes** — previews and applies *only* what your hardware actually needs:
   - Pins detected GameLoop executables to your **discrete GPU** *(skipped automatically on integrated-only PCs)*.
   - Applies **`HIGHDPIAWARE`** *(when Windows scaling is above 100%)* and disables Fullscreen Optimizations *(preserving any existing custom compatibility flags)*.
   - Disables **Xbox Game DVR** *(only if currently enabled)*.
   - Adds **Windows Defender** exclusions for detected GameLoop folders/processes *(only if Windows Defender is actively running and exclusions are missing)*.

---

## Extra Tips for Lag-Free Gameplay

- **Close heavy VM/container tools** (Docker Desktop, WSL2, VMware, VirtualBox) before gaming to prevent hypervisor CPU contention.
- **Windows Memory Integrity (HVCI):** Click **Open Core Isolation (HVCI)** in the app — turning Memory Integrity **OFF** (requires reboot) reduces virtualization overhead during emulator gameplay.
- **High Polling-Rate Gaming Mice (1000 Hz+):** If you experience camera hitching in emulators on a 1000 Hz+ gaming mouse (Logitech, Razer, SteelSeries, Pulsar, etc.), lowering the mouse Report Rate to **250–500 Hz** significantly stabilizes virtual touch camera movement.

---

## Building the Standalone `.exe` Locally

No .NET SDK or Visual Studio required — compiles using Windows' built-in .NET Framework 4.x compiler (`csc.exe`):
```powershell
powershell -ExecutionPolicy Bypass -File .\build-exe.ps1
```
Output: `dist\GameLoop-Doctor.exe` (single-file ~90 KB executable with `GameLoop-Doctor.ps1` embedded and UAC elevation manifest).

---

## License

[MIT](LICENSE) — free to use, audit, fork, and share with fellow gamers.
