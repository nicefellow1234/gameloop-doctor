<#
.SYNOPSIS
    GameLoop Doctor - All-in-One Windows Desktop App & CLI Tool for GameLoop (Classic & 7.0)

.DESCRIPTION
    Detects and fixes common GameLoop 7.0 ("Androws") & Classic GameLoop (TxGameAssistant) issues:
      - Completely removes GameLoop 7.0 ("Androws" / TenStore Android Connect)
      - Helps restore Classic GameLoop (TxGameAssistant) with ultra-sharp 2K Gaming Resolution
      - Permanently blocks forced GameLoop 7.0 silent auto-updates (4-layer shield)
      - Smart Store Toggle (-AllowStore / -BlockStore) so PUBG Mobile APK updates still work
      - Applies RTX/Discrete GPU pinning, High-DPI fix, Disable Fullscreen Optimizations,
        Xbox Game DVR disable, Windows Defender VHD/VDI exclusions, and lag diagnostics
      - 100% Anti-Cheat Safe: NEVER modifies PUBG Mobile internal game files or memory.

.EXAMPLE
    # Launch the Desktop GUI App (auto-elevates via UAC):
    powershell -ExecutionPolicy Bypass -File .\GameLoop-Doctor.ps1

.EXAMPLE
    # One-click CLI modes:
    .\GameLoop-Doctor.ps1 -Diagnose
    .\GameLoop-Doctor.ps1 -RemoveGameLoop7
    .\GameLoop-Doctor.ps1 -LockUpdates
    .\GameLoop-Doctor.ps1 -AllowStore
    .\GameLoop-Doctor.ps1 -OptimizeWindows
    .\GameLoop-Doctor.ps1 -UnblockAll
#>
[CmdletBinding()]
param(
    [switch]$Diagnose,
    [switch]$RemoveGameLoop7,
    [switch]$LockUpdates,
    [switch]$AllowStore,
    [switch]$OptimizeWindows,
    [switch]$UnblockAll,
    [switch]$NoElevate
)

$ErrorActionPreference = 'Continue'
$script:AppVersion = '1.0.0'
$script:FwRulePrefix = 'GameLoopDoctor_Block7Upgrade_'

# ============================================================================
# 1. ELEVATION HELPER (Auto-UAC for GUI & Admin CLI actions)
# ============================================================================
function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

$isCliMode = $Diagnose -or $RemoveGameLoop7 -or $LockUpdates -or $AllowStore -or $OptimizeWindows -or $UnblockAll
$needsAdmin = (-not $Diagnose) -and (-not $NoElevate)

if ($needsAdmin -and -not (Test-IsAdmin)) {
    if ($PSCommandPath) {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        if ($RemoveGameLoop7) { $argList += '-RemoveGameLoop7' }
        if ($LockUpdates)     { $argList += '-LockUpdates' }
        if ($AllowStore)      { $argList += '-AllowStore' }
        if ($OptimizeWindows) { $argList += '-OptimizeWindows' }
        if ($UnblockAll)      { $argList += '-UnblockAll' }
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
            exit 0
        } catch {
            Write-Warning "UAC elevation was cancelled. Launching in read-only diagnostic mode..."
        }
    }
}

# ============================================================================
# 2. CORE DISCOVERY & HELPER FUNCTIONS
# ============================================================================
function Get-FixedDrives {
    try {
        return @(Get-PSDrive -PSProvider FileSystem | Where-Object {
            $_.Root -match '^[A-Z]:\\$' -and ([System.IO.DriveInfo]::new($_.Root).DriveType -eq 'Fixed')
        } | Select-Object -ExpandProperty Root)
    } catch {
        return @('C:\', 'D:\', 'E:\', 'F:\') | Where-Object { Test-Path $_ }
    }
}

function Get-GameLoop7LockTargets {
    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($drv in (Get-FixedDrives)) {
        $targets.Add((Join-Path $drv 'Program Files\Tencent\GameLoop'))
        $targets.Add((Join-Path $drv 'Program Files\Tencent\GameLoopData'))
    }
    $targets.Add("$env:APPDATA\Tencent\GameLoop")
    $targets.Add("$env:APPDATA\Tencent\DeskUpdate")
    return $targets.ToArray()
}

function Find-ClassicGameLoop {
    foreach ($drv in (Get-FixedDrives)) {
        foreach ($rel in @('Program Files\TxGameAssistant', 'Program Files (x86)\TxGameAssistant', 'TxGameAssistant')) {
            $cand = Join-Path $drv $rel
            if (Test-Path -LiteralPath (Join-Path $cand 'AppMarket\AppMarket.exe')) {
                $uiExe = Join-Path $cand 'UI\AndroidEmulatorEn.exe'
                if (-not (Test-Path -LiteralPath $uiExe)) {
                    $uiExe = Join-Path $cand 'UI\AndroidEmulatorEx.exe'
                }
                return [PSCustomObject]@{
                    Root         = $cand
                    AppMarketExe = (Join-Path $cand 'AppMarket\AppMarket.exe')
                    EmulatorExe  = $(if (Test-Path -LiteralPath $uiExe) { $uiExe } else { $null })
                    HasEngineUI  = (Test-Path -LiteralPath $uiExe)
                }
            }
        }
    }
    return $null
}

function Find-GameLoop7Installs {
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($drv in (Get-FixedDrives)) {
        foreach ($rel in @('Program Files\Tencent\GameLoop', 'Program Files\Tencent\GameLoopData')) {
            $cand = Join-Path $drv $rel
            if (Test-Path -LiteralPath $cand) {
                # Check if non-empty (locked empty placeholder is NOT an active install)
                $items = @(Get-ChildItem -LiteralPath $cand -Force -ErrorAction SilentlyContinue)
                if ($items.Count -gt 0) {
                    $found.Add($cand)
                }
            }
        }
    }
    return $found.ToArray()
}

function Find-CachedSilentUpgraders {
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($drv in (Get-FixedDrives)) {
        $shared = Join-Path $drv 'Temp\TxGameDownload\MobileGamePCShared'
        if (Test-Path -LiteralPath $shared) {
            Get-ChildItem -LiteralPath $shared -Filter 'com_tencent_gameloop_*.exe' -ErrorAction SilentlyContinue | ForEach-Object {
                $hits.Add($_.FullName)
            }
        }
    }
    return $hits.ToArray()
}

function Find-ClassicInstaller {
    $searchDirs = @(
        "$env:USERPROFILE\Downloads\Programs",
        "$env:USERPROFILE\Downloads",
        "$env:USERPROFILE\Desktop"
    )
    foreach ($d in $searchDirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $hit = Get-ChildItem -LiteralPath $d -Filter 'GLP_installer*.exe' -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Test-FolderWriteLocked {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        foreach ($rule in $acl.Access) {
            if ($rule.AccessControlType -eq 'Deny' -and $rule.IdentityReference.Value -match 'Everyone|S-1-1-0') {
                return $true
            }
        }
    } catch { return $true }
    return $false
}

function Get-Diagnostics {
    $gl7Dirs    = Find-GameLoop7Installs
    $gl7Svc     = Get-Service -Name 'GameLoopService' -ErrorAction SilentlyContinue
    $classic    = Find-ClassicGameLoop
    $upgraders  = Find-CachedSilentUpgraders
    $installer  = Find-ClassicInstaller

    # Firewall rule check
    $fwRule = Get-NetFirewallRule -DisplayName "${script:FwRulePrefix}AppMarket" -ErrorAction SilentlyContinue
    if (-not $fwRule) {
        # Also detect legacy script rule name
        $fwRule = Get-NetFirewallRule -DisplayName 'GameLoopClassic_Block7Upgrade_AppMarket' -ErrorAction SilentlyContinue
    }
    $fwStatus = if (-not $fwRule) { 'Not Set' } elseif ($fwRule.Enabled -eq 'True') { 'Blocked (Protected)' } else { 'Temporarily Allowed' }

    # NTFS lock coverage
    $lockTargets = Get-GameLoop7LockTargets
    $lockedCount = @($lockTargets | Where-Object { Test-FolderWriteLocked $_ }).Count

    # System / Lag checks
    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $os   = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $ramPct = if ($os -and $os.TotalVisibleMemorySize -gt 0) {
        [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 0)
    } else { 0 }

    $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue
    $hvciOn = ($dg -and $dg.VirtualizationBasedSecurityStatus -eq 2 -and ($dg.SecurityServicesRunning -contains 2))

    $gameDvr = (Get-ItemProperty -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -ErrorAction SilentlyContinue).GameDVR_Enabled
    $hags    = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -ErrorAction SilentlyContinue).HwSchMode

    $dockerRunning = @(Get-Process -Name 'com.docker.sailor', 'Docker Desktop', 'vmmemWSL', 'vmmem' -ErrorAction SilentlyContinue).Count -gt 0
    $nvOverlay     = @(Get-Process -Name 'NVIDIA Overlay', 'NVIDIA Share', 'NVIDIA Broadcast' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique)

    # GPU Pinning check for Classic or 7.0
    $gpuRegPath = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $gpuPinned = $false
    if ($classic -and $classic.EmulatorExe -and (Test-Path $gpuRegPath)) {
        $val = (Get-ItemProperty -Path $gpuRegPath -Name $classic.EmulatorExe -ErrorAction SilentlyContinue).($classic.EmulatorExe)
        if ($val -match 'GpuPreference=2') { $gpuPinned = $true }
    }

    return [PSCustomObject]@{
        IsAdmin          = (Test-IsAdmin)
        GameLoop7Dirs    = $gl7Dirs
        GameLoop7Svc     = ($null -ne $gl7Svc)
        HasGameLoop7     = ($gl7Dirs.Count -gt 0) -or ($null -ne $gl7Svc)
        Classic          = $classic
        CachedUpgraders  = $upgraders
        ClassicInstaller = $installer
        FirewallStatus   = $fwStatus
        LockedFolders    = $lockedCount
        TotalLockTargets = $lockTargets.Count
        GPUs             = $gpus
        RamUsedPercent   = $ramPct
        HvciEnabled      = $hvciOn
        GameDvrEnabled   = ($gameDvr -eq 1)
        HagsEnabled      = ($hags -eq 2)
        DockerRunning    = $dockerRunning
        NvidiaBgApps     = $nvOverlay
        ClassicGpuPinned = $gpuPinned
    }
}

# ============================================================================
# 3. ACTION FUNCTIONS (Shared by both GUI and CLI)
# ============================================================================
function Invoke-RemoveGameLoop7 {
    param([scriptblock]$Log = { param($m) Write-Host $m })

    if (-not (Test-IsAdmin)) {
        & $Log "[ERROR] Administrator privileges are required to remove GameLoop 7.0."
        return $false
    }

    & $Log "=== Removing GameLoop 7.0 ('Androws' / TenStore Android Connect) ==="

    # 1. Stop processes
    $procs = @(
        'GameLoop', 'GameLoopEmulator', 'GameLoopVm', 'GameLoopAssistant',
        'GameLoopLauncher', 'GameLoopDldSvr', 'GameLoopService',
        'GLABoxHeadless', 'GLABoxSVC', 'GameLoopVfs', 'Uninstall'
    )
    foreach ($p in $procs) {
        $found = Get-Process -Name $p -ErrorAction SilentlyContinue
        if ($found) {
            $found | Stop-Process -Force -ErrorAction SilentlyContinue
            & $Log "  Stopped process: $p"
        }
    }

    # 2. Stop & delete GameLoopService
    if (Get-Service -Name 'GameLoopService' -ErrorAction SilentlyContinue) {
        Stop-Service -Name 'GameLoopService' -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        & sc.exe delete GameLoopService | Out-Null
        & $Log "  Deleted Windows Service: GameLoopService"
    }
    Start-Sleep -Seconds 1

    # 3. Remove folders across all fixed drives + AppData
    $dirsToRemove = New-Object System.Collections.Generic.List[string]
    foreach ($drv in (Get-FixedDrives)) {
        $dirsToRemove.Add((Join-Path $drv 'Program Files\Tencent\GameLoop'))
        $dirsToRemove.Add((Join-Path $drv 'Program Files\Tencent\GameLoopData'))
    }
    $dirsToRemove.Add("$env:APPDATA\Tencent\GameLoop")
    $dirsToRemove.Add("$env:APPDATA\Tencent\Androws")
    $dirsToRemove.Add("$env:LOCALAPPDATA\Temp\Tencent\GameLoop")

    foreach ($d in $dirsToRemove) {
        if (Test-Path -LiteralPath $d) {
            & takeown.exe /F $d /R /A /D Y 2>&1 | Out-Null
            & icacls.exe $d /remove:d "*S-1-1-0" /T /C /Q 2>&1 | Out-Null
            & icacls.exe $d /grant "*S-1-5-32-544:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
            try {
                Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop
                & $Log "  Removed folder: $d"
            } catch {
                cmd.exe /c "rd /s /q `"$d`"" 2>&1 | Out-Null
                if (-not (Test-Path -LiteralPath $d)) {
                    & $Log "  Removed folder: $d"
                } else {
                    & $Log "  [WARN] Could not fully delete $d (locked until reboot)."
                }
            }
        }
    }

    # 4. Delete cached silent-upgrader binaries
    foreach ($u in (Find-CachedSilentUpgraders)) {
        Remove-Item -LiteralPath $u -Force -ErrorAction SilentlyContinue
        & $Log "  Deleted cached 7.0 silent upgrader: $u"
    }

    # 5. Remove 7.0 shortcuts
    $shortcuts = @(
        'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\GameLoop.lnk',
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\GameLoop.lnk",
        "$env:PUBLIC\Desktop\GameLoop.lnk",
        "$env:USERPROFILE\Desktop\GameLoop.lnk"
    )
    foreach ($lnk in $shortcuts) {
        if (Test-Path -LiteralPath $lnk) {
            Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
            & $Log "  Removed shortcut: $lnk"
        }
    }

    # 6. Clean 7.0 Registry entries
    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        foreach ($sub in @('GameLoop', 'TenStore-Android-Connect')) {
            $full = Join-Path $root $sub
            if (Test-Path -LiteralPath $full) {
                Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
                & $Log "  Removed uninstall key: $full"
            }
        }
        $igKey = Join-Path $root 'com.tencent.ig'
        if (Test-Path -LiteralPath $igKey) {
            $uninst = (Get-ItemProperty -LiteralPath $igKey -ErrorAction SilentlyContinue).UninstallString
            if ($uninst -and ($uninst -match 'Tencent\\GameLoop')) {
                Remove-Item -LiteralPath $igKey -Recurse -Force -ErrorAction SilentlyContinue
                & $Log "  Removed 7.0 PUBG uninstall entry: $igKey"
            }
        }
    }

    foreach ($rk in @('HKCU:\Software\Tencent\GameLoop', 'HKLM:\SOFTWARE\Tencent\GameLoop', 'HKLM:\SOFTWARE\WOW6432Node\Tencent\GameLoop')) {
        if (Test-Path -LiteralPath $rk) {
            Remove-Item -LiteralPath $rk -Recurse -Force -ErrorAction SilentlyContinue
            & $Log "  Removed registry key: $rk"
        }
    }

    # Clean HKCU AppCompat / GPU entries belonging to 7.0
    foreach ($rpath in @('HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers', 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences')) {
        if (Test-Path $rpath) {
            $props = (Get-Item -Path $rpath).Property
            foreach ($prop in $props) {
                if ($prop -match 'Tencent\\GameLoop') {
                    Remove-ItemProperty -Path $rpath -Name $prop -ErrorAction SilentlyContinue
                    & $Log "  Cleaned 7.0 registry value: $prop"
                }
            }
        }
    }

    & $Log "[OK] GameLoop 7.0 completely removed! Classic installer & caches preserved."
    return $true
}

function Invoke-LockUpdates {
    param(
        [switch]$ForceFirewallBlock,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )

    if (-not (Test-IsAdmin)) {
        & $Log "[ERROR] Administrator privileges are required to lock out GameLoop 7.0 updates."
        return $false
    }

    & $Log "=== Applying 4-Layer Anti-GameLoop-7.0 Update Shield ==="

    # Layer 1: NTFS Write-Deny on all GameLoop 7.0 destinations across every fixed drive
    foreach ($t in (Get-GameLoop7LockTargets)) {
        $drv = [System.IO.Path]::GetPathRoot($t)
        if (-not (Test-Path -LiteralPath $drv)) { continue }

        if (Test-Path -LiteralPath $t) {
            & icacls.exe $t /remove:d "*S-1-1-0" /T /C /Q 2>&1 | Out-Null
            Get-ChildItem -LiteralPath $t -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            New-Item -ItemType Directory -Path $t -Force | Out-Null
        }
        & icacls.exe $t /deny "*S-1-1-0:(OI)(CI)(W,WD,AD,DC)" /C /Q 2>&1 | Out-Null
        & $Log "  [Layer 1] NTFS Write-Locked: $t"
    }

    # Layer 2: Delete cached silent upgraders & neutralize classic internal updater binaries
    foreach ($u in (Find-CachedSilentUpgraders)) {
        Remove-Item -LiteralPath $u -Force -ErrorAction SilentlyContinue
        & $Log "  [Layer 2] Deleted silent upgrader: $u"
    }

    $classic = Find-ClassicGameLoop
    if ($classic) {
        foreach ($rel in @('AppMarket\GF186\tupdate.exe', 'AppMarket\Update.exe', 'UI\Update.exe')) {
            $u = Join-Path $classic.Root $rel
            if (Test-Path -LiteralPath $u) {
                $newName = "$([System.IO.Path]::GetFileName($u)).disabled"
                Rename-Item -LiteralPath $u -NewName $newName -Force -ErrorAction SilentlyContinue
                & $Log "  [Layer 2] Disabled classic updater: $u"
            }
        }
    }

    foreach ($rk in @('HKCU:\Software\Tencent\MobileGamePC', 'HKCU:\Software\Tencent\MobileGamePC\AppMarket')) {
        if (Test-Path -LiteralPath $rk) {
            New-ItemProperty -Path $rk -Name 'AutoUpdate' -Value 0 -PropertyType DWord -Force | Out-Null
            New-ItemProperty -Path $rk -Name 'EnableAutoUpdate' -Value 0 -PropertyType DWord -Force | Out-Null
        }
    }

    # Layer 3: Smart Firewall Block on AppMarket.exe
    # Remove any old/duplicate rules first
    Get-NetFirewallRule -DisplayName "${script:FwRulePrefix}*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Get-NetFirewallRule -DisplayName 'GameLoopClassic_Block7Upgrade_*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule

    if ($classic) {
        if ($classic.HasEngineUI -or $ForceFirewallBlock) {
            New-NetFirewallRule `
                -DisplayName "${script:FwRulePrefix}AppMarket" `
                -Direction Outbound `
                -Action Block `
                -Program $classic.AppMarketExe `
                -Profile Any `
                -Description "Blocks Classic GameLoop AppMarket from downloading GameLoop 7.0 updates. AndroidEmulatorEn.exe & PUBG Mobile remain 100% online." | Out-Null
            & $Log "  [Layer 3] Windows Firewall Outbound BLOCK enabled for: $($classic.AppMarketExe)"

            # Create Direct-Launch PUBG Mobile shortcut (bypasses AppMarket completely!)
            if ($classic.EmulatorExe) {
                $wsh = New-Object -ComObject WScript.Shell
                $lnkPath = "$env:USERPROFILE\Desktop\PUBG Mobile (Classic Direct).lnk"
                $sc = $wsh.CreateShortcut($lnkPath)
                $sc.TargetPath = $classic.EmulatorExe
                $sc.Arguments = '-vm 100'
                $sc.WorkingDirectory = Split-Path -Parent $classic.EmulatorExe
                $sc.Description = 'Launch Classic GameLoop Emulator directly without AppMarket'
                $sc.Save()
                & $Log "  [Layer 3] Created Desktop shortcut: $lnkPath"
            }
        } else {
            & $Log "  [SMART GUARD] Classic UI\AndroidEmulatorEn.exe is NOT installed yet (games still downloading)."
            & $Log "  [SMART GUARD] NTFS 7.0 lockdown IS ACTIVE, but AppMarket.exe Firewall block was skipped so PUBG can finish downloading!"
            & $Log "  [SMART GUARD] Click 'Lock Out 7.0 Updates' again once PUBG Mobile finishes installing and opens."
        }
    } else {
        & $Log "  [INFO] Classic TxGameAssistant not installed yet. NTFS 7.0 lockdown is active on all drives."
    }

    & $Log "[OK] Anti-GameLoop-7.0 update protection applied!"
    return $true
}

function Invoke-AllowStore {
    param([scriptblock]$Log = { param($m) Write-Host $m })
    if (-not (Test-IsAdmin)) {
        & $Log "[ERROR] Administrator privileges are required to toggle the Firewall rule."
        return $false
    }
    $rules = @(Get-NetFirewallRule -DisplayName "${script:FwRulePrefix}AppMarket" -ErrorAction SilentlyContinue) +
             @(Get-NetFirewallRule -DisplayName 'GameLoopClassic_Block7Upgrade_AppMarket' -ErrorAction SilentlyContinue)
    if ($rules.Count -gt 0) {
        $rules | Disable-NetFirewallRule
        & $Log "[OK] AppMarket.exe is now ALLOWED online to download/update PUBG Mobile."
        & $Log "     NTFS write-lock on Tencent\GameLoop folders REMAINS ACTIVE so 7.0 still cannot install."
        & $Log "     Re-click 'Lock Out 7.0 Updates' once PUBG finishes installing."
    } else {
        & $Log "[INFO] No AppMarket Firewall block rule is currently active — downloads are already allowed."
    }
    return $true
}

function Invoke-OptimizeWindows {
    param([scriptblock]$Log = { param($m) Write-Host $m })

    & $Log "=== Optimizing Windows GPU, High-DPI, Game DVR & Defender Exclusions ==="

    $gpuReg = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $dpiReg = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
    if (-not (Test-Path $gpuReg)) { New-Item -Path $gpuReg -Force | Out-Null }
    if (-not (Test-Path $dpiReg)) { New-Item -Path $dpiReg -Force | Out-Null }

    $exesToTune = New-Object System.Collections.Generic.List[string]
    $classic = Find-ClassicGameLoop
    if ($classic) {
        foreach ($rel in @('UI\AndroidEmulatorEn.exe', 'UI\AndroidEmulatorEx.exe', 'UI\AndroidEmulator.exe', 'UI\aow_exe.exe', 'AppMarket\AppMarket.exe')) {
            $p = Join-Path $classic.Root $rel
            if (Test-Path -LiteralPath $p) { $exesToTune.Add($p) }
        }
    }
    foreach ($gl7 in (Find-GameLoop7Installs)) {
        if ($gl7 -match 'GameLoop$') {
            Get-ChildItem -LiteralPath (Join-Path $gl7 'Application') -Recurse -Include 'GameLoopEmulator.exe','GameLoopVm.exe','GameLoop.exe' -ErrorAction SilentlyContinue | ForEach-Object {
                $exesToTune.Add($_.FullName)
            }
        }
    }

    foreach ($exe in $exesToTune) {
        Set-ItemProperty -Path $gpuReg -Name $exe -Value 'GpuPreference=2;' -Type String
        Set-ItemProperty -Path $dpiReg -Name $exe -Value '~ HIGHDPIAWARE DISABLEDXMAXIMIZEDWINDOWEDMODE' -Type String
        & $Log "  Pinned High-Perf GPU + High-DPI + No FSO: $exe"
    }

    # Disable Xbox Game DVR capture hook
    if (-not (Test-Path 'HKCU:\System\GameConfigStore')) { New-Item -Path 'HKCU:\System\GameConfigStore' -Force | Out-Null }
    Set-ItemProperty -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 0 -Type DWord
    if (-not (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR')) { New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Force | Out-Null }
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -Value 0 -Type DWord
    & $Log "  Disabled Xbox Game DVR background capture hook."

    # Windows Defender Exclusions (Admin)
    if (Test-IsAdmin) {
        $exclPaths = New-Object System.Collections.Generic.List[string]
        if ($classic) { $exclPaths.Add($classic.Root) }
        foreach ($drv in (Get-FixedDrives)) {
            $td = Join-Path $drv 'Temp\TxGameDownload'
            if (Test-Path -LiteralPath $td) { $exclPaths.Add($td) }
        }
        foreach ($gl7 in (Find-GameLoop7Installs)) { $exclPaths.Add($gl7) }

        if ($exclPaths.Count -gt 0) {
            try {
                Add-MpPreference -ExclusionPath $exclPaths.ToArray() -ErrorAction Stop
                Add-MpPreference -ExclusionProcess 'AndroidEmulatorEn.exe','AndroidEmulatorEx.exe','aow_exe.exe','GameLoopVm.exe','GameLoopEmulator.exe' -ErrorAction Stop
                & $Log "  Added Windows Defender exclusions for: $($exclPaths -join ', ')"
            } catch {
                & $Log "  [WARN] Defender exclusion skipped: $($_.Exception.Message)"
            }
        }
    } else {
        & $Log "  [INFO] Run as Administrator to also add Windows Defender exclusions."
    }

    & $Log "[OK] Windows optimizations complete!"
    return $true
}

function Invoke-UnblockAll {
    param([scriptblock]$Log = { param($m) Write-Host $m })
    if (-not (Test-IsAdmin)) {
        & $Log "[ERROR] Administrator privileges are required to undo locks."
        return $false
    }
    & $Log "=== Reversing All GameLoop Doctor Blocks ==="
    Get-NetFirewallRule -DisplayName "${script:FwRulePrefix}*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Get-NetFirewallRule -DisplayName 'GameLoopClassic_Block7Upgrade_*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    & $Log "  Removed Firewall rules."

    foreach ($t in (Get-GameLoop7LockTargets)) {
        if (Test-Path -LiteralPath $t) {
            & icacls.exe $t /remove:d "*S-1-1-0" /C /Q 2>&1 | Out-Null
            $items = @(Get-ChildItem -LiteralPath $t -Force -ErrorAction SilentlyContinue)
            if ($items.Count -eq 0) {
                Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue
            }
            & $Log "  Unlocked: $t"
        }
    }

    $classic = Find-ClassicGameLoop
    if ($classic) {
        foreach ($rel in @('AppMarket\GF186\tupdate.exe.disabled', 'AppMarket\Update.exe.disabled', 'UI\Update.exe.disabled')) {
            $p = Join-Path $classic.Root $rel
            if (Test-Path -LiteralPath $p) {
                $orig = [System.IO.Path]::GetFileName($p) -replace '\.disabled$', ''
                Rename-Item -LiteralPath $p -NewName $orig -Force -ErrorAction SilentlyContinue
                & $Log "  Restored updater: $orig"
            }
        }
    }
    & $Log "[OK] All blocks cleanly reversed."
    return $true
}

# ============================================================================
# 4. HEADLESS CLI EXECUTION MODE
# ============================================================================
if ($isCliMode) {
    if ($Diagnose) {
        $d = Get-Diagnostics
        Write-Host "================ GameLoop Doctor v$($script:AppVersion) Diagnostics ================" -ForegroundColor Cyan
        Write-Host ("  Admin Rights        : {0}" -f $d.IsAdmin)
        Write-Host ("  GameLoop 7.0 Found  : {0} ({1})" -f $d.HasGameLoop7, ($(if ($d.GameLoop7Dirs.Count) { $d.GameLoop7Dirs -join ', ' } else { 'None' })))
        Write-Host ("  Classic GameLoop    : {0}" -f $(if ($d.Classic) { "$($d.Classic.Root) (EngineUI=$($d.Classic.HasEngineUI))" } else { 'Not Installed' }))
        Write-Host ("  Local Classic Setup : {0}" -f $(if ($d.ClassicInstaller) { $d.ClassicInstaller } else { 'Not found in Downloads' }))
        Write-Host ("  Cached 7.0 Updaters : {0}" -f $d.CachedUpgraders.Count)
        Write-Host ("  NTFS 7.0 Lockdown   : {0}/{1} targets locked" -f $d.LockedFolders, $d.TotalLockTargets)
        Write-Host ("  AppMarket Firewall  : {0}" -f $d.FirewallStatus)
        Write-Host ("  GPUs                : {0}" -f ($d.GPUs -join ' | '))
        Write-Host ("  Classic GPU Pinned  : {0}" -f $d.ClassicGpuPinned)
        Write-Host ("  RAM Used            : {0}%" -f $d.RamUsedPercent)
        Write-Host ("  Win11 HVCI (VBS)    : {0}" -f $(if ($d.HvciEnabled) { 'ON (may add Hyper-V stutter)' } else { 'OFF (Good)' }))
        Write-Host ("  Xbox Game DVR       : {0}" -f $(if ($d.GameDvrEnabled) { 'ON (recommend OFF)' } else { 'OFF (Good)' }))
        Write-Host ("  HAGS                : {0}" -f $(if ($d.HagsEnabled) { 'ON' } else { 'OFF' }))
        Write-Host ("  Docker/WSL Running  : {0}" -f $d.DockerRunning)
        Write-Host ("  NVIDIA Bg Apps      : {0}" -f $(if ($d.NvidiaBgApps.Count) { $d.NvidiaBgApps -join ', ' } else { 'None' }))
    }
    if ($RemoveGameLoop7) { Invoke-RemoveGameLoop7 | Out-Null }
    if ($LockUpdates)     { Invoke-LockUpdates | Out-Null }
    if ($AllowStore)      { Invoke-AllowStore | Out-Null }
    if ($OptimizeWindows) { Invoke-OptimizeWindows | Out-Null }
    if ($UnblockAll)      { Invoke-UnblockAll | Out-Null }
    exit 0
}

# ============================================================================
# 5. NATIVE WINDOWS WPF DESKTOP APP (Zero Dependencies — Built into Windows!)
# ============================================================================
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="GameLoop Doctor v1.0 - Classic Restore, Anti-7.0 Shield &amp; Lag Optimizer"
        Height="740" Width="960" MinHeight="660" MinWidth="860"
        WindowStartupLocation="CenterScreen"
        Background="#0F111A" Foreground="#E5E9F0" FontFamily="Segoe UI">
    <Window.Resources>
        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background" Value="#181C2A"/>
            <Setter Property="BorderBrush" Value="#2A3148"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="10"/>
            <Setter Property="Padding" Value="14"/>
            <Setter Property="Margin" Value="0,0,0,10"/>
        </Style>
        <Style x:Key="ActionBtn" TargetType="Button">
            <Setter Property="Background" Value="#2563EB"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="14,9"/>
            <Setter Property="Margin" Value="0,0,8,8"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="7" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Opacity" Value="0.88"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bd" Property="Opacity" Value="0.45"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="185"/>
        </Grid.RowDefinitions>

        <!-- HEADER -->
        <DockPanel Grid.Row="0" Margin="0,0,0,12">
            <StackPanel DockPanel.Dock="Left">
                <TextBlock Text="GameLoop Doctor" FontSize="24" FontWeight="Bold" Foreground="#F8FAFC"/>
                <TextBlock Text="Restore Classic GameLoop (2K), Permanently Block Forced 7.0 Auto-Updates, &amp; Fix Lag (100% Anti-Cheat Safe)"
                           FontSize="12" Foreground="#94A3B8" Margin="0,2,0,0"/>
            </StackPanel>
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                <Border x:Name="AdminBadge" Background="#14532D" CornerRadius="6" Padding="10,5" Margin="0,0,8,0">
                    <TextBlock x:Name="AdminBadgeText" Text="ADMIN READY" FontSize="11" FontWeight="Bold" Foreground="#86EFAC"/>
                </Border>
                <Button x:Name="BtnRefresh" Content="Rescan PC" Style="{StaticResource ActionBtn}" Background="#334155" Margin="0"/>
            </StackPanel>
        </DockPanel>

        <!-- LIVE DIAGNOSTICS CARDS -->
        <Grid Grid.Row="1" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="10"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="10"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0">
                <StackPanel>
                    <TextBlock Text="GAMELOOP EDITION" FontSize="11" FontWeight="Bold" Foreground="#60A5FA"/>
                    <TextBlock x:Name="TxtEdition" Text="Scanning..." FontSize="14" FontWeight="SemiBold" Margin="0,6,0,2" TextWrapping="Wrap"/>
                    <TextBlock x:Name="TxtEditionSub" Text="" FontSize="11.5" Foreground="#94A3B8" TextWrapping="Wrap"/>
                </StackPanel>
            </Border>

            <Border Grid.Column="2" Style="{StaticResource Card}" Margin="0">
                <StackPanel>
                    <TextBlock Text="ANTI-7.0 UPDATE SHIELD" FontSize="11" FontWeight="Bold" Foreground="#34D399"/>
                    <TextBlock x:Name="TxtShield" Text="Scanning..." FontSize="14" FontWeight="SemiBold" Margin="0,6,0,2" TextWrapping="Wrap"/>
                    <TextBlock x:Name="TxtShieldSub" Text="" FontSize="11.5" Foreground="#94A3B8" TextWrapping="Wrap"/>
                </StackPanel>
            </Border>

            <Border Grid.Column="4" Style="{StaticResource Card}" Margin="0">
                <StackPanel>
                    <TextBlock Text="LAG &amp; GPU HEALTH" FontSize="11" FontWeight="Bold" Foreground="#FBBF24"/>
                    <TextBlock x:Name="TxtPerf" Text="Scanning..." FontSize="14" FontWeight="SemiBold" Margin="0,6,0,2" TextWrapping="Wrap"/>
                    <TextBlock x:Name="TxtPerfSub" Text="" FontSize="11.5" Foreground="#94A3B8" TextWrapping="Wrap"/>
                </StackPanel>
            </Border>
        </Grid>

        <!-- MAIN WORKFLOW PANELS -->
        <Grid Grid.Row="2" Margin="0,4,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="12"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- LEFT: RESTORE CLASSIC & BLOCK 7.0 -->
            <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel>
                        <TextBlock Text="1. Restore Classic GameLoop &amp; Block 7.0 Forever" FontSize="15" FontWeight="Bold" Foreground="#F1F5F9" Margin="0,0,0,8"/>

                        <TextBlock Text="Step 1 — Completely uninstall GameLoop 7.0 ('Androws'), GameLoopService, locked Tencent folders, and cached silent-upgraders:"
                                   FontSize="12" Foreground="#CBD5E1" TextWrapping="Wrap" Margin="0,0,0,6"/>
                        <WrapPanel>
                            <Button x:Name="BtnRemove7" Content="Remove GameLoop 7.0" Style="{StaticResource ActionBtn}" Background="#DC2626"/>
                            <Button x:Name="BtnLaunchClassic" Content="Launch Classic Installer" Style="{StaticResource ActionBtn}" Background="#0284C7"/>
                        </WrapPanel>

                        <Separator Background="#2A3148" Margin="0,6,0,10"/>

                        <TextBlock Text="Step 2 — Lock out forced 7.0 auto-updates (4-layer NTFS + Updater + Smart Firewall + Direct PUBG Shortcut):"
                                   FontSize="12" Foreground="#CBD5E1" TextWrapping="Wrap" Margin="0,0,0,6"/>
                        <WrapPanel>
                            <Button x:Name="BtnLockUpdates" Content="Lock Out 7.0 Updates" Style="{StaticResource ActionBtn}" Background="#059669"/>
                            <Button x:Name="BtnAllowStore" Content="Allow Store (Download/Update PUBG)" Style="{StaticResource ActionBtn}" Background="#D97706"/>
                        </WrapPanel>

                        <TextBlock Text="Note: If PUBG Mobile is still downloading, use 'Allow Store' — your NTFS 7.0 lockdown stays active so 7.0 still cannot install! Re-click 'Lock Out 7.0 Updates' once PUBG opens."
                                   FontSize="11" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,2,0,10"/>

                        <Button x:Name="BtnUnblockAll" Content="Undo All Blocks (Restore Defaults)" Style="{StaticResource ActionBtn}" Background="#475569" HorizontalAlignment="Left"/>
                    </StackPanel>
                </ScrollViewer>
            </Border>

            <!-- RIGHT: LAG, GPU & DIAGNOSTIC ADVISOR -->
            <Border Grid.Column="2" Style="{StaticResource Card}" Margin="0">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel>
                        <TextBlock Text="2. Performance, Sharpness &amp; Lag Fixes" FontSize="15" FontWeight="Bold" Foreground="#F1F5F9" Margin="0,0,0,8"/>

                        <TextBlock Text="One-click Windows optimizations for Classic GameLoop (and 7.0): Pins Discrete GPU, fixes 125%/150% DPI blur, disables Fullscreen Optimizations &amp; Xbox Game DVR, and adds Defender VHD/VDI exclusions:"
                                   FontSize="12" Foreground="#CBD5E1" TextWrapping="Wrap" Margin="0,0,0,8"/>
                        <WrapPanel>
                            <Button x:Name="BtnOptimize" Content="Apply One-Click Performance Fixes" Style="{StaticResource ActionBtn}" Background="#7C3AED"/>
                            <Button x:Name="BtnOpenSecurity" Content="Open Core Isolation (HVCI)" Style="{StaticResource ActionBtn}" Background="#334155"/>
                        </WrapPanel>

                        <Separator Background="#2A3148" Margin="0,6,0,10"/>

                        <TextBlock Text="System Lag Checklist (Auto-Detected):" FontSize="12.5" FontWeight="SemiBold" Foreground="#E2E8F0" Margin="0,0,0,4"/>
                        <TextBlock x:Name="TxtAdvisor" Text="Scanning hardware &amp; background apps..." FontSize="11.5" Foreground="#CBD5E1" TextWrapping="Wrap" LineHeight="18"/>
                    </StackPanel>
                </ScrollViewer>
            </Border>
        </Grid>

        <!-- ACTIVITY LOG -->
        <Border Grid.Row="3" Style="{StaticResource Card}" Margin="0">
            <DockPanel>
                <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
                    <TextBlock Text="LIVE ACTIVITY LOG" FontSize="11" FontWeight="Bold" Foreground="#94A3B8" VerticalAlignment="Center"/>
                    <Button x:Name="BtnCopyLog" Content="Copy Log" DockPanel.Dock="Right" Padding="10,3" FontSize="11"
                            Background="#334155" Foreground="#E2E8F0" BorderThickness="0" Cursor="Hand"/>
                </DockPanel>
                <TextBox x:Name="TxtLog" IsReadOnly="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                         Background="#0B0D14" Foreground="#A7F3D0" BorderThickness="0" Padding="8"
                         FontFamily="Consolas" FontSize="11.5" TextWrapping="NoWrap"/>
            </DockPanel>
        </Border>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$AdminBadge      = $window.FindName('AdminBadge')
$AdminBadgeText  = $window.FindName('AdminBadgeText')
$TxtEdition      = $window.FindName('TxtEdition')
$TxtEditionSub   = $window.FindName('TxtEditionSub')
$TxtShield       = $window.FindName('TxtShield')
$TxtShieldSub    = $window.FindName('TxtShieldSub')
$TxtPerf         = $window.FindName('TxtPerf')
$TxtPerfSub      = $window.FindName('TxtPerfSub')
$TxtAdvisor      = $window.FindName('TxtAdvisor')
$TxtLog          = $window.FindName('TxtLog')

$BtnRefresh       = $window.FindName('BtnRefresh')
$BtnRemove7       = $window.FindName('BtnRemove7')
$BtnLaunchClassic = $window.FindName('BtnLaunchClassic')
$BtnLockUpdates   = $window.FindName('BtnLockUpdates')
$BtnAllowStore    = $window.FindName('BtnAllowStore')
$BtnUnblockAll    = $window.FindName('BtnUnblockAll')
$BtnOptimize      = $window.FindName('BtnOptimize')
$BtnOpenSecurity  = $window.FindName('BtnOpenSecurity')
$BtnCopyLog       = $window.FindName('BtnCopyLog')

$WriteLog = {
    param([string]$Message)
    $ts = (Get-Date).ToString('HH:mm:ss')
    $TxtLog.AppendText("[$ts] $Message`r`n")
    $TxtLog.ScrollToEnd()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
}

$RefreshUI = {
    $d = Get-Diagnostics
    if ($d.IsAdmin) {
        $AdminBadge.Background = '#14532D'
        $AdminBadgeText.Text = 'ADMIN READY'
        $AdminBadgeText.Foreground = '#86EFAC'
    } else {
        $AdminBadge.Background = '#7F1D1D'
        $AdminBadgeText.Text = 'NOT ADMIN (LIMITED)'
        $AdminBadgeText.Foreground = '#FCA5A5'
    }

    # Card 1: Edition
    if ($d.HasGameLoop7 -and $d.Classic) {
        $TxtEdition.Text = "Both 7.0 & Classic Found"
        $TxtEdition.Foreground = '#FBBF24'
        $TxtEditionSub.Text = "7.0: $($d.GameLoop7Dirs -join ', ')`nClassic: $($d.Classic.Root)"
    } elseif ($d.HasGameLoop7) {
        $TxtEdition.Text = "GameLoop 7.0 Installed"
        $TxtEdition.Foreground = '#F87171'
        $TxtEditionSub.Text = "Paths: $($d.GameLoop7Dirs -join ', ')`nService: $($d.GameLoop7Svc)"
    } elseif ($d.Classic) {
        $TxtEdition.Text = "Classic GameLoop Active"
        $TxtEdition.Foreground = '#4ADE80'
        $eng = if ($d.Classic.HasEngineUI) { "Engine UI ready" } else { "Waiting for first game install" }
        $TxtEditionSub.Text = "$($d.Classic.Root)`n$eng"
    } else {
        $TxtEdition.Text = "No GameLoop Installed"
        $TxtEdition.Foreground = '#94A3B8'
        $TxtEditionSub.Text = if ($d.ClassicInstaller) { "Installer found: $(Split-Path -Leaf $d.ClassicInstaller)" } else { "Ready for fresh Classic install" }
    }

    # Card 2: Shield
    $shieldGood = ($d.LockedFolders -ge 4) -and ($d.CachedUpgraders.Count -eq 0)
    if ($shieldGood -and $d.FirewallStatus -eq 'Blocked (Protected)') {
        $TxtShield.Text = "Fully Protected"
        $TxtShield.Foreground = '#4ADE80'
    } elseif ($shieldGood) {
        $TxtShield.Text = "NTFS Locked (Store Open)"
        $TxtShield.Foreground = '#FBBF24'
    } else {
        $TxtShield.Text = "Unprotected (7.0 Can Auto-Install)"
        $TxtShield.Foreground = '#F87171'
    }
    $TxtShieldSub.Text = "NTFS Locks: $($d.LockedFolders)/$($d.TotalLockTargets) | Store FW: $($d.FirewallStatus)`nCached 7.0 Upgraders: $($d.CachedUpgraders.Count)"

    # Card 3: Performance
    $issues = New-Object System.Collections.Generic.List[string]
    if ($d.GameDvrEnabled)  { $issues.Add("Xbox Game DVR is ON (adds frame spikes)") }
    if ($d.HvciEnabled)     { $issues.Add("Win11 Memory Integrity (HVCI) is ON (adds Hyper-V/VM stutter)") }
    if ($d.DockerRunning)   { $issues.Add("Docker Desktop / WSL2 is running (quit before gaming!)") }
    if ($d.RamUsedPercent -ge 70) { $issues.Add("High host RAM usage ($($d.RamUsedPercent)%) — close heavy Chrome tabs") }
    if ($d.NvidiaBgApps.Count -gt 0) { $issues.Add("Background NVIDIA app running: $($d.NvidiaBgApps -join ', ')") }
    if ($d.Classic -and $d.Classic.HasEngineUI -and -not $d.ClassicGpuPinned) { $issues.Add("Classic emulator not yet pinned to Discrete GPU") }

    if ($issues.Count -eq 0) {
        $TxtPerf.Text = "Optimal"
        $TxtPerf.Foreground = '#4ADE80'
        $TxtPerfSub.Text = "RAM: $($d.RamUsedPercent)% | Game DVR: OFF | Clean"
        $TxtAdvisor.Text = "• All core checks look great!`n• In Classic GameLoop Settings -> Game, set Gaming Resolution to Ultra HD 2K.`n• If using a 1000 Hz gaming mouse and camera stutters, lower polling rate to 250-500 Hz."
    } else {
        $TxtPerf.Text = "$($issues.Count) Lag Factor(s) Found"
        $TxtPerf.Foreground = '#FBBF24'
        $TxtPerfSub.Text = "RAM: $($d.RamUsedPercent)% | GPUs: $($d.GPUs.Count)"
        $TxtAdvisor.Text = ($issues | ForEach-Object { "• $_" }) -join "`n"
    }
}

$BtnRefresh.Add_Click({
    & $WriteLog "Rescanning system..."
    & $RefreshUI
    & $WriteLog "Scan complete."
})

$BtnRemove7.Add_Click({
    $ans = [System.Windows.MessageBox]::Show(
        "This will completely remove GameLoop 7.0 ('Androws'), GameLoopService, and its data folders.`n`nYour Classic GLP_installer and cached classic packages will NOT be touched.`n`nProceed?",
        "Confirm Remove GameLoop 7.0", 'YesNo', 'Warning')
    if ($ans -eq 'Yes') {
        Invoke-RemoveGameLoop7 -Log $WriteLog | Out-Null
        & $RefreshUI
    }
})

$BtnLaunchClassic.Add_Click({
    $inst = Find-ClassicInstaller
    if ($inst) {
        & $WriteLog "Launching local Classic GameLoop installer: $inst"
        Start-Process -FilePath $inst
    } else {
        & $WriteLog "No local GLP_installer*.exe found in Downloads. Opening gameloop.com..."
        Start-Process "https://www.gameloop.com/"
    }
})

$BtnLockUpdates.Add_Click({
    Invoke-LockUpdates -Log $WriteLog | Out-Null
    & $RefreshUI
})

$BtnAllowStore.Add_Click({
    Invoke-AllowStore -Log $WriteLog | Out-Null
    & $RefreshUI
})

$BtnUnblockAll.Add_Click({
    $ans = [System.Windows.MessageBox]::Show(
        "Remove all Firewall blocks, NTFS folder locks, and restore renamed updaters?",
        "Confirm Undo All Blocks", 'YesNo', 'Question')
    if ($ans -eq 'Yes') {
        Invoke-UnblockAll -Log $WriteLog | Out-Null
        & $RefreshUI
    }
})

$BtnOptimize.Add_Click({
    Invoke-OptimizeWindows -Log $WriteLog | Out-Null
    & $RefreshUI
})

$BtnOpenSecurity.Add_Click({
    & $WriteLog "Opening Windows Security -> Core Isolation..."
    Start-Process "windowsdefender://coreisolation"
})

$BtnCopyLog.Add_Click({
    [System.Windows.Clipboard]::SetText($TxtLog.Text)
    & $WriteLog "Copied log to clipboard."
})

$window.Add_Loaded({
    & $WriteLog "GameLoop Doctor v$($script:AppVersion) ready. Running initial system scan..."
    & $RefreshUI
    & $WriteLog "Initial scan complete."
})

$window.ShowDialog() | Out-Null
