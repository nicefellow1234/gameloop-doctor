# GameLoop Doctor

**All-in-one Windows Desktop App & PowerShell tool** to remove buggy **GameLoop 7.0 ("Androws" / TenStore Android Connect)**, restore **Classic GameLoop (`TxGameAssistant`)** with sharp **Ultra HD 2K**, **permanently block forced 7.0 silent auto-updates**, and fix common lag/stutter bottlenecks on Windows 10 & 11.

> **100% Anti-Cheat Safe:** GameLoop Doctor only manages Windows host files, Firewall rules, NTFS folder permissions, and Windows GPU/DPI settings. It **never** touches PUBG Mobile internal files (`UserCustom.ini`, `Active.sav`, `data.vhd`) or game memory.

---

## Why This Tool Exists

If Classic GameLoop (`TxGameAssistant`) silently upgraded your PC to **GameLoop 7.0 ("Androws")**, you probably hit:
- **Blurry ~720p graphics** on *Smooth / Super Smooth* (GameLoop 7.0 removed Classic GameLoop's `Gaming Resolution: Ultra HD 2K` engine hook).
- **Random mouse camera freezes & missed keys** (GameLoop 7.0's Hyper-V HCS input pipe + `Raw="1"` `0 ms` same-finger resets + 1000 Hz gaming mice).
- **Mid-game lag spikes** (Hyper-V HCS contending with Docker/WSL2, Windows 11 Memory Integrity / HVCI, dual-GPU compositing, and Defender scanning `data.vhd`).
- **Repeated forced upgrades:** Even after reinstalling Classic GameLoop, `AppMarket.exe` silently drops `com_tencent_gameloop_silent_update_up_client_*.exe` and `com_tencent_gameloop_yybinstaller_*.exe` into `Temp\TxGameDownload\MobileGamePCShared\` and force-installs 7.0 again (hopping to another drive if one folder is blocked!).

---

## Quick Start (3 Ways to Run — Zero Dependencies!)

Works out of the box on **Windows 10 & Windows 11** (no Python, Node, or .NET SDK install required):

### Option 1 — One-Line PowerShell Command (Fastest!)
Open **PowerShell** (or **Windows Terminal**) and run:
```powershell
irm https://raw.githubusercontent.com/<YOUR_GITHUB_USERNAME>/gameloop-doctor/main/GameLoop-Doctor.ps1 -OutFile "$env:TEMP\GameLoop-Doctor.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\GameLoop-Doctor.ps1"
```
*(Replace `<YOUR_GITHUB_USERNAME>` with your GitHub username after pushing.)*

### Option 2 — Double-Click Desktop App (From Cloned Repo / ZIP)
1. Download or clone this repository.
2. Double-click **`Launch-GameLoop-Doctor.bat`** (or run `dist\GameLoop-Doctor.exe` if you download a release).
3. Accept the standard Windows Administrator (UAC) prompt — the dark native desktop window opens immediately.

### Option 3 — Headless One-Click CLI Commands (Power Users)
```powershell
# Scan PC without changing anything (no Admin needed)
.\GameLoop-Doctor.ps1 -Diagnose

# Step 1: Completely remove GameLoop 7.0 ("Androws")
.\GameLoop-Doctor.ps1 -RemoveGameLoop7

# Step 2: Lock out forced 7.0 auto-updates (run AFTER PUBG Mobile finishes installing!)
.\GameLoop-Doctor.ps1 -LockUpdates

# Temporarily allow GameLoop Store online to download/update PUBG Mobile (keeps NTFS 7.0 lock active!)
.\GameLoop-Doctor.ps1 -AllowStore

# Apply GPU pinning, High-DPI blur fix, Game DVR off, & Defender exclusions
.\GameLoop-Doctor.ps1 -OptimizeWindows

# Reverse all blocks cleanly
.\GameLoop-Doctor.ps1 -UnblockAll
```

---

## Recommended Step-by-Step Workflow

1. **Remove GameLoop 7.0:** Click **Remove GameLoop 7.0** — stops & deletes `GameLoopService`, takes ownership of locked `Program Files\Tencent\GameLoop` / `GameLoopData` folders across all drives, deletes cached `com_tencent_gameloop_*.exe` silent upgraders, and cleans 7.0 registry entries *(without deleting your Classic `GLP_installer*.exe` or cached classic packages)*.
2. **Install Classic GameLoop & PUBG Mobile:** Click **Launch Classic Installer**, install Classic GameLoop (`TxGameAssistant`), and let **PUBG Mobile** finish downloading and open once.
   - In Classic GameLoop **Settings → Game**, set **Gaming Resolution** to **Ultra HD 2K**.
3. **Lock Out Forced 7.0 Updates Forever:** Click **Lock Out 7.0 Updates**. This applies a **4-layer shield**:
   - **Layer 1 (NTFS Deny-Write Lockdown):** Creates empty write-denied `Program Files\Tencent\GameLoop` & `GameLoopData` placeholders on **every fixed drive (`C:`, `D:`, `E:`, `F:`, ...)** plus `%APPDATA%\Tencent\GameLoop` & `DeskUpdate`. Even if an updater runs as Administrator/SYSTEM, Windows NTFS rejects every write.
   - **Layer 2 (Updater Cleanup):** Deletes `com_tencent_gameloop_*.exe` silent upgraders, disables classic `tupdate.exe` / `Update.exe`, and sets `AutoUpdate = 0`.
   - **Layer 3 (Smart Firewall Block + Direct Shortcut):** Blocks `AppMarket.exe` outbound via Windows Defender Firewall while keeping **`AndroidEmulatorEn.exe` and PUBG Mobile 100% online**, and puts a **`PUBG Mobile (Classic Direct)`** shortcut on your Desktop (`AndroidEmulatorEn.exe -vm 100`).
   - **Layer 4 (Smart Download Guard):** Automatically detects if `UI\AndroidEmulatorEn.exe` isn't installed yet (meaning PUBG is still downloading) and keeps `AppMarket.exe` open until your game finishes installing!
4. **Optimize Windows for Zero Lag:** Click **Apply One-Click Performance Fixes** to pin the emulator to your discrete GPU (NVIDIA/AMD), fix 125%/150% DPI scaling blur (`HIGHDPIAWARE`), disable Fullscreen Optimizations & Xbox Game DVR, and add Windows Defender exclusions for `TxGameAssistant` & `Temp\TxGameDownload`.

---

## How to Update PUBG Mobile Later (Without Getting Upgraded to 7.0)

- **Small in-game updates & resource packs:** Work automatically inside PUBG Mobile — no action needed!
- **Major PUBG Mobile APK updates (every ~2 months):**
  1. Open **GameLoop Doctor** and click **Allow Store (Download/Update PUBG)** *(or run `.\GameLoop-Doctor.ps1 -AllowStore`)*.
     - Your **NTFS write-lock on `Tencent\GameLoop` stays active**, so GameLoop 7.0 still cannot install while the store is open.
  2. Open Classic GameLoop and update PUBG Mobile.
  3. Click **Lock Out 7.0 Updates** again once PUBG opens.

---

## Extra Tips for Lag-Free Gameplay

- **Quit Docker Desktop / WSL2** before gaming (another Hyper-V VM running alongside your emulator causes micro-stutters).
- **Windows 11 Memory Integrity (HVCI):** Click **Open Core Isolation (HVCI)** in the app — turning Memory Integrity **OFF** (requires reboot) removes hypervisor overhead during emulator gameplay.
- **High Polling-Rate Gaming Mice (1000 Hz+):** If you ever experience camera hitching in emulators on a 1000 Hz mouse (e.g., Logitech G HUB), lowering Report Rate to **250–500 Hz** drastically stabilizes virtual touch input.

---

## Building the Standalone `.exe` Locally

No .NET SDK or Visual Studio required — uses Windows' built-in .NET Framework 4.x compiler (`csc.exe`):
```powershell
powershell -ExecutionPolicy Bypass -File .\build-exe.ps1
```
Output: `dist\GameLoop-Doctor.exe` (single-file ~15 KB executable with `GameLoop-Doctor.ps1` embedded and UAC elevation manifest).

---

## License

[MIT](LICENSE) — free to use, audit, fork, and share with fellow gamers.
