<#
.SYNOPSIS
    GameLoop Doctor - Generic, Detect-First Windows Desktop App & CLI Tool for GameLoop (Classic & 7.0)

.DESCRIPTION
    Auto-detects your PC's drives, hardware (NVIDIA/AMD/Intel GPUs, DPI scaling, Windows Defender,
    Hyper-V/HVCI), and GameLoop installations (standard or custom folders) BEFORE making any changes:
      - Safely detects and removes GameLoop 7.0 ("Androws" / TenStore Android Connect)
      - Helps restore Classic GameLoop (TxGameAssistant) with ultra-sharp 2K Gaming Resolution
      - Permanently blocks forced GameLoop 7.0 emulator auto-updates WHILE KEEPING GAME DOWNLOADS
        & GAME UPDATES 100% WORKING (PUBG Mobile, CODM, Free Fire, etc. stay online in AppMarket!):
          * Layer 1: All-drive NTFS write-lock on GameLoop 7.0 install/data/DB destinations
          * Layer 2: Surgically disables bundled 7.0/client upgraders (AndrowsInstaller.exe,
            pcyyb_installer.exe, PcyybAssistant.exe, tupdate.exe, Update.exe) & neutralizes
            cached com_tencent_gameloop_*.exe silent upgraders into 0-byte locked stubs
          * Layer 3: Sets Classic AutoUpdate=0 & creates a Direct Launch Desktop shortcut
          * Optional Strict Mode (-StrictBlockStore / -AllowStore) if you also want to block Store traffic
      - Detect-first Windows performance optimizer (Discrete GPU pin only if dGPU detected, High-DPI blur fix,
        Fullscreen Optimizations off, Xbox Game DVR off, Windows Defender exclusions only if Defender is active)
      - Supports -DryRun preview mode in CLI and pre-action confirmation previews in the Desktop GUI
      - 100% Anti-Cheat Safe: NEVER modifies game files (UserCustom.ini, Active.sav, data.vhd) or memory.

.EXAMPLE
    # Launch the Desktop GUI App (auto-elevates via UAC):
    powershell -ExecutionPolicy Bypass -File .\GameLoop-Doctor.ps1

.EXAMPLE
    # Read-only PC diagnostics (no Admin required, changes nothing):
    .\GameLoop-Doctor.ps1 -Diagnose

.EXAMPLE
    # Preview what any action would change on THIS PC without applying anything:
    .\GameLoop-Doctor.ps1 -RemoveGameLoop7 -DryRun
    .\GameLoop-Doctor.ps1 -LockUpdates -DryRun
    .\GameLoop-Doctor.ps1 -OptimizeWindows -DryRun

.EXAMPLE
    # Apply actions via CLI:
    .\GameLoop-Doctor.ps1 -RemoveGameLoop7
    .\GameLoop-Doctor.ps1 -LockUpdates        # Blocks 7.0 emulator upgrade; keeps game downloads/updates working!
    .\GameLoop-Doctor.ps1 -OptimizeWindows
    .\GameLoop-Doctor.ps1 -StrictBlockStore   # Optional: also block AppMarket.exe outbound in Firewall
    .\GameLoop-Doctor.ps1 -AllowStore         # Re-allow AppMarket.exe outbound if Strict Mode was enabled
    .\GameLoop-Doctor.ps1 -UnblockAll         # Reverse all blocks cleanly
#>
[CmdletBinding()]
param(
    [switch]$Diagnose,
    [switch]$RemoveGameLoop7,
    [switch]$LockUpdates,
    [switch]$StrictBlockStore,
    [switch]$AllowStore,
    [switch]$OptimizeWindows,
    [switch]$UnblockAll,
    [switch]$DryRun,
    [switch]$NoElevate
)

$ErrorActionPreference = 'Continue'
$script:AppVersion   = '1.0.0'
$script:FwRulePrefix = 'GameLoopDoctor_Block7Upgrade_'

# Classic GameLoop bundled 7.0 / self-updater executables (NEVER includes AppMarket.exe, GameDownload.exe, or game engines!)
$script:ClassicBundledUpdaters = @(
    'AppMarket\AndrowsInstaller.exe',
    'AppMarket\PcyybAssistant.exe',
    'AppMarket\GF186\tupdate.exe',
    'AppMarket\Update.exe',
    'UI\pcyyb_installer.exe',
    'UI\Update.exe'
)

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

$isCliMode  = $Diagnose -or $RemoveGameLoop7 -or $LockUpdates -or $StrictBlockStore -or $AllowStore -or $OptimizeWindows -or $UnblockAll
$needsAdmin = (-not $Diagnose) -and (-not $DryRun) -and (-not $NoElevate)

if ($needsAdmin -and -not (Test-IsAdmin)) {
    if ($PSCommandPath) {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        if ($RemoveGameLoop7)  { $argList += '-RemoveGameLoop7' }
        if ($LockUpdates)      { $argList += '-LockUpdates' }
        if ($StrictBlockStore) { $argList += '-StrictBlockStore' }
        if ($AllowStore)       { $argList += '-AllowStore' }
        if ($OptimizeWindows)  { $argList += '-OptimizeWindows' }
        if ($UnblockAll)       { $argList += '-UnblockAll' }
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
            exit 0
        } catch {
            Write-Warning "UAC elevation was cancelled. Running in read-only diagnostic mode..."
        }
    }
}

# ============================================================================
# 2. UNIVERSAL DISCOVERY & HARDWARE DETECTION (Zero PC-Specific Assumptions)
# ============================================================================
function Get-FixedNtfsDrives {
    $drives = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            if ($d.DriveType -eq [System.IO.DriveType]::Fixed -and
                $d.IsReady -and
                $d.DriveFormat -eq 'NTFS' -and
                $d.TotalSize -gt 1GB) {
                $drives.Add($d.RootDirectory.FullName)
            }
        }
    } catch { }
    if ($drives.Count -eq 0 -and $env:SystemDrive) {
        $drives.Add("$($env:SystemDrive)\")
    }
    return @($drives | Select-Object -Unique)
}

function Get-KnownDownloadsDirs {
    $dirs = New-Object System.Collections.Generic.List[string]
    try {
        $shellFolders = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue
        $dlRaw = $shellFolders.'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($dlRaw) {
            $dlExpanded = [Environment]::ExpandEnvironmentVariables($dlRaw)
            if (Test-Path -LiteralPath $dlExpanded) {
                $dirs.Add((Join-Path $dlExpanded 'Programs'))
                $dirs.Add($dlExpanded)
            }
        }
    } catch { }

    $fallbackDl = Join-Path $env:USERPROFILE 'Downloads'
    $dirs.Add((Join-Path $fallbackDl 'Programs'))
    $dirs.Add($fallbackDl)

    $desktop = [Environment]::GetFolderPath('Desktop')
    if ($desktop) { $dirs.Add($desktop) }

    return @($dirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
}

function Resolve-CleanDirPath {
    param([string]$RawPath)
    if ([string]::IsNullOrWhiteSpace($RawPath)) { return $null }
    $p = $RawPath.Trim()
    if ($p -match '^"([^"]+)"') {
        $p = $Matches[1]
    } elseif ($p -match '^([A-Za-z]:\\[^,]+?\.(?:exe|msi))') {
        $p = $Matches[1]
    }
    $p = $p.Trim('"', ' ')
    if ($p -match '\.(exe|msi|lnk)$') {
        $p = Split-Path -Parent $p
    }
    return $p.TrimEnd('\')
}

function Find-ClassicGameLoop {
    $candidates = New-Object System.Collections.Generic.List[string]

    # 1. Registry-based discovery (catches custom user install folders)
    $regHints = @(
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Tencent\MobileGamePC\UI'; Names = @('InstallPath', 'AppMarketPath') },
        @{ Path = 'HKLM:\SOFTWARE\Tencent\MobileGamePC\UI';             Names = @('InstallPath', 'AppMarketPath') },
        @{ Path = 'HKCU:\Software\Tencent\MobileGamePC';                Names = @('InstallPath', 'AppMarketPath', 'UIPath') },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Tencent\MobileGamePC';    Names = @('InstallPath', 'AppMarketPath') }
    )
    foreach ($h in $regHints) {
        if (-not (Test-Path -LiteralPath $h.Path)) { continue }
        $props = Get-ItemProperty -LiteralPath $h.Path -ErrorAction SilentlyContinue
        foreach ($n in $h.Names) {
            $val = $props.$n
            if ($val) {
                $dir = Resolve-CleanDirPath $val
                if ($dir) {
                    $candidates.Add($dir)
                    $parent = Split-Path -Parent $dir
                    if ($parent) { $candidates.Add($parent) }
                }
            }
        }
    }

    foreach ($uRoot in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
        if (-not (Test-Path -LiteralPath $uRoot)) { continue }
        foreach ($sub in (Get-ChildItem -LiteralPath $uRoot -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
            $str = "$($p.InstallLocation) $($p.UninstallString) $($p.DisplayIcon)"
            if ($str -match 'TxGameAssistant|AppMarket\.exe') {
                foreach ($field in @($p.InstallLocation, $p.UninstallString, $p.DisplayIcon)) {
                    $dir = Resolve-CleanDirPath $field
                    if ($dir) {
                        $candidates.Add($dir)
                        $parent = Split-Path -Parent $dir
                        if ($parent) { $candidates.Add($parent) }
                    }
                }
            }
        }
    }

    # 2. Standard folders across every fixed NTFS drive
    foreach ($drv in (Get-FixedNtfsDrives)) {
        foreach ($rel in @('Program Files\TxGameAssistant', 'Program Files (x86)\TxGameAssistant', 'TxGameAssistant', 'Games\TxGameAssistant')) {
            $candidates.Add((Join-Path $drv $rel))
        }
    }

    foreach ($cand in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        $appMarket = Join-Path $cand 'AppMarket\AppMarket.exe'
        if (Test-Path -LiteralPath $appMarket) {
            $uiExe = $null
            foreach ($name in @('UI\AndroidEmulatorEn.exe', 'UI\AndroidEmulatorEx.exe', 'UI\AndroidEmulator.exe')) {
                $testUi = Join-Path $cand $name
                if (Test-Path -LiteralPath $testUi) {
                    $uiExe = $testUi
                    break
                }
            }
            return [PSCustomObject]@{
                Root         = $cand
                AppMarketExe = $appMarket
                EmulatorExe  = $uiExe
                HasEngineUI  = ($null -ne $uiExe)
            }
        }
    }
    return $null
}

function Find-GameLoop7Installs {
    $candidates = New-Object System.Collections.Generic.List[string]

    # 1. Discover from GameLoopService binary path
    $svc = Get-CimInstance Win32_Service -Filter "Name='GameLoopService'" -ErrorAction SilentlyContinue
    if ($svc -and $svc.PathName) {
        $svcDir = Resolve-CleanDirPath $svc.PathName
        if ($svcDir) {
            if ($svcDir -match '^(.+?\\GameLoop)(?:\\|$)') { $candidates.Add($Matches[1]) }
            else { $candidates.Add($svcDir) }
        }
    }

    # 2. Discover from Registry Uninstall & Software keys
    foreach ($uRoot in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
        if (-not (Test-Path -LiteralPath $uRoot)) { continue }
        foreach ($keyName in @('GameLoop', 'TenStore-Android-Connect')) {
            $full = Join-Path $uRoot $keyName
            if (Test-Path -LiteralPath $full) {
                $p = Get-ItemProperty -LiteralPath $full -ErrorAction SilentlyContinue
                foreach ($field in @($p.InstallLocation, $p.UninstallString)) {
                    $dir = Resolve-CleanDirPath $field
                    if ($dir -and ($dir -notmatch 'TxGameAssistant')) {
                        if ($dir -match '^(.+?\\GameLoop)(?:\\|$)') { $candidates.Add($Matches[1]) }
                        else { $candidates.Add($dir) }
                    }
                }
            }
        }
    }

    foreach ($rk in @('HKCU:\Software\Tencent\GameLoop', 'HKLM:\SOFTWARE\Tencent\GameLoop', 'HKLM:\SOFTWARE\WOW6432Node\Tencent\GameLoop')) {
        if (-not (Test-Path -LiteralPath $rk)) { continue }
        $p = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
        foreach ($prop in @('InstallPath', 'InstallDir', 'DataPath', 'RootPath')) {
            if ($p.$prop) {
                $dir = Resolve-CleanDirPath $p.$prop
                if ($dir -and ($dir -notmatch 'TxGameAssistant')) { $candidates.Add($dir) }
            }
        }
    }

    # 3. Standard paths across every fixed NTFS drive
    foreach ($drv in (Get-FixedNtfsDrives)) {
        foreach ($rel in @(
            'Program Files\Tencent\GameLoop',
            'Program Files\Tencent\GameLoopData',
            'Program Files (x86)\Tencent\GameLoop',
            'Program Files (x86)\Tencent\GameLoopData'
        )) {
            $candidates.Add((Join-Path $drv $rel))
        }
    }

    $found = New-Object System.Collections.Generic.List[string]
    foreach ($cand in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $cand) {
            # Empty write-locked placeholder folder is NOT an active GameLoop 7.0 install
            $items = @(Get-ChildItem -LiteralPath $cand -Force -ErrorAction SilentlyContinue)
            if ($items.Count -gt 0) {
                $found.Add($cand)
            }
        }
    }
    return @($found | Select-Object -Unique)
}

function Get-GameLoop7LockTargets {
    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($drv in (Get-FixedNtfsDrives)) {
        $targets.Add((Join-Path $drv 'Program Files\Tencent\GameLoop'))
        $targets.Add((Join-Path $drv 'Program Files\Tencent\GameLoopData'))
    }
    foreach ($d in (Find-GameLoop7Installs)) {
        if (-not $targets.Contains($d)) { $targets.Add($d) }
    }
    if ($env:APPDATA) {
        $targets.Add((Join-Path $env:APPDATA 'Tencent\GameLoop'))
        $targets.Add((Join-Path $env:APPDATA 'Tencent\DeskUpdate'))
    }
    if ($env:LOCALAPPDATA) {
        $targets.Add((Join-Path $env:LOCALAPPDATA 'Tencent\GameLoop'))
    }
    return @($targets | Select-Object -Unique)
}

function Find-TxGameDownloadDirs {
    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($rk in @('HKCU:\Software\Tencent\MobileGamePC', 'HKLM:\SOFTWARE\WOW6432Node\Tencent\MobileGamePC')) {
        if (-not (Test-Path -LiteralPath $rk)) { continue }
        $p = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
        foreach ($n in @('TempPath', 'DownloadPath', 'TxGameDownloadPath')) {
            if ($p.$n -and (Test-Path -LiteralPath $p.$n)) {
                $dirs.Add($p.$n.TrimEnd('\'))
            }
        }
    }
    foreach ($drv in (Get-FixedNtfsDrives)) {
        $td = Join-Path $drv 'Temp\TxGameDownload'
        if (Test-Path -LiteralPath $td) { $dirs.Add($td) }
    }
    if ($env:TEMP) {
        $userTd = Join-Path $env:TEMP 'TxGameDownload'
        if (Test-Path -LiteralPath $userTd) { $dirs.Add($userTd) }
    }
    return @($dirs | Select-Object -Unique)
}

function Test-PathWriteLocked {
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

function Find-CachedSilentUpgraders {
    # Returns ONLY real (non-empty) active GameLoop 7.0 silent upgrader executables (excludes our 0-byte neutralized stubs)
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($td in (Find-TxGameDownloadDirs)) {
        foreach ($sub in @($td, (Join-Path $td 'MobileGamePCShared'))) {
            if (Test-Path -LiteralPath $sub) {
                Get-ChildItem -LiteralPath $sub -Filter 'com_tencent_gameloop_*.exe' -ErrorAction SilentlyContinue | Where-Object {
                    $_.Length -gt 0
                } | ForEach-Object {
                    $hits.Add($_.FullName)
                }
            }
        }
    }
    return @($hits | Select-Object -Unique)
}

function Find-NeutralizedUpgraderStubs {
    # Returns 0-byte write-denied stubs created by GameLoop Doctor so Undo All can clean them cleanly
    $stubs = New-Object System.Collections.Generic.List[string]
    foreach ($td in (Find-TxGameDownloadDirs)) {
        foreach ($sub in @($td, (Join-Path $td 'MobileGamePCShared'))) {
            if (Test-Path -LiteralPath $sub) {
                Get-ChildItem -LiteralPath $sub -Filter 'com_tencent_gameloop_*.exe' -ErrorAction SilentlyContinue | Where-Object {
                    $_.Length -eq 0 -and (Test-PathWriteLocked $_.FullName)
                } | ForEach-Object {
                    $stubs.Add($_.FullName)
                }
            }
        }
    }
    return @($stubs | Select-Object -Unique)
}

function Find-ActiveClassicBundledUpdaters {
    param($Classic)
    $active = New-Object System.Collections.Generic.List[string]
    if (-not $Classic) { return @() }
    foreach ($rel in $script:ClassicBundledUpdaters) {
        $p = Join-Path $Classic.Root $rel
        if (Test-Path -LiteralPath $p) { $active.Add($p) }
    }
    return $active.ToArray()
}

function Find-DisabledClassicBundledUpdaters {
    param($Classic)
    $disabled = New-Object System.Collections.Generic.List[string]
    if (-not $Classic) { return @() }
    foreach ($rel in $script:ClassicBundledUpdaters) {
        $p = Join-Path $Classic.Root "$rel.disabled"
        if (Test-Path -LiteralPath $p) { $disabled.Add($p) }
    }
    return $disabled.ToArray()
}

function Find-ClassicInstaller {
    foreach ($d in (Get-KnownDownloadsDirs)) {
        $hit = Get-ChildItem -LiteralPath $d -Filter 'GLP_installer*.exe' -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Get-GpuProfile {
    $virtualPattern    = 'Microsoft Basic|Remote|Virtual|Parsec|Citrix|Meta |Oculus|DisplayLink|Indirect|LuminonCore|TeamViewer|AnyDesk'
    $discretePattern   = 'NVIDIA|GeForce|RTX|GTX|Quadro|Radeon RX|Radeon \(TM\) RX|Radeon Pro|FirePro|Intel\(R\) Arc|Intel Arc'
    $integratedPattern = 'Intel\(R\) UHD|Intel\(R\) HD|Intel\(R\) Iris|Intel\(R\) Graphics|Radeon\(TM\) Graphics|AMD Radeon Graphics|Vega'

    $allRaw = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -and ($_.Name -notmatch $virtualPattern)
    } | Select-Object -ExpandProperty Name -Unique)

    $discrete   = @($allRaw | Where-Object { $_ -match $discretePattern })
    $integrated = @($allRaw | Where-Object { ($_ -notmatch $discretePattern) -and ($_ -match $integratedPattern) })

    return [PSCustomObject]@{
        AllGpus         = $allRaw
        DiscreteGpus    = $discrete
        IntegratedGpus  = $integrated
        HasDiscreteGpu  = ($discrete.Count -gt 0)
        IsHybridDualGpu = ($discrete.Count -gt 0 -and $integrated.Count -gt 0)
    }
}

function Get-DisplayScalingPercent {
    try {
        $dpi = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name 'AppliedDPI' -ErrorAction SilentlyContinue).AppliedDPI
        if (-not $dpi) {
            $dpi = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'LogPixels' -ErrorAction SilentlyContinue).LogPixels
        }
        if ($dpi -and [int]$dpi -gt 0) {
            return [int][math]::Round(([double]$dpi / 96.0) * 100)
        }
    } catch { }
    return 100
}

function Get-DefenderState {
    $svc = Get-Service -Name 'WinDefend' -ErrorAction SilentlyContinue
    $running   = ($svc -and $svc.Status -eq 'Running')
    $exclPaths = @()
    $exclProcs = @()
    $readable  = $false

    if ($running) {
        try {
            $mp = Get-MpPreference -ErrorAction Stop
            if ($mp.ExclusionPath)    { $exclPaths = @($mp.ExclusionPath) }
            if ($mp.ExclusionProcess) { $exclProcs = @($mp.ExclusionProcess) }
            $readable = $true
        } catch { }
    }

    return [PSCustomObject]@{
        ServiceRunning = $running
        CanQuery       = $readable
        ExclusionPaths = $exclPaths
        ExclusionProcs = $exclProcs
    }
}

function Get-AllGameLoopExecutables {
    $exes = New-Object System.Collections.Generic.List[string]
    $classic = Find-ClassicGameLoop
    if ($classic) {
        foreach ($rel in @('UI\AndroidEmulatorEn.exe', 'UI\AndroidEmulatorEx.exe', 'UI\AndroidEmulator.exe', 'UI\aow_exe.exe', 'AppMarket\AppMarket.exe')) {
            $p = Join-Path $classic.Root $rel
            if (Test-Path -LiteralPath $p) { $exes.Add($p) }
        }
    }
    foreach ($gl7 in (Find-GameLoop7Installs)) {
        $appDir   = Join-Path $gl7 'Application'
        $scanRoot = if (Test-Path -LiteralPath $appDir) { $appDir } else { $gl7 }
        Get-ChildItem -LiteralPath $scanRoot -Recurse -Include 'GameLoopEmulator.exe', 'GameLoopVm.exe', 'GameLoop.exe' -ErrorAction SilentlyContinue | ForEach-Object {
            $exes.Add($_.FullName)
        }
    }
    return @($exes | Select-Object -Unique)
}

function Get-Diagnostics {
    $drives           = Get-FixedNtfsDrives
    $gl7Dirs          = Find-GameLoop7Installs
    $gl7Svc           = Get-Service -Name 'GameLoopService' -ErrorAction SilentlyContinue
    $classic          = Find-ClassicGameLoop
    $upgraders        = Find-CachedSilentUpgraders
    $stubs            = Find-NeutralizedUpgraderStubs
    $activeUpdaters   = Find-ActiveClassicBundledUpdaters -Classic $classic
    $disabledUpdaters = Find-DisabledClassicBundledUpdaters -Classic $classic
    $installer        = Find-ClassicInstaller

    # Firewall rule check (optional Strict Mode only — default keeps game downloads 100% online!)
    $fwRule   = Get-NetFirewallRule -DisplayName "${script:FwRulePrefix}AppMarket" -ErrorAction SilentlyContinue
    $fwBlocked = ($fwRule -and $fwRule.Enabled -eq 'True')
    $fwStatus = if ($fwBlocked) { 'Blocked (Strict Mode)' } else { 'Online (Game Downloads Working)' }

    # NTFS lock coverage across all detected fixed NTFS drives + AppData/LocalAppData
    $lockTargets = Get-GameLoop7LockTargets
    $lockedCount = @($lockTargets | Where-Object { Test-PathWriteLocked $_ }).Count

    # Generic hardware & OS checks
    $gpuProfile = Get-GpuProfile
    $dpiPct     = Get-DisplayScalingPercent
    $defender   = Get-DefenderState

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $totalRamGb = if ($os -and $os.TotalVisibleMemorySize -gt 0) { [math]::Round($os.TotalVisibleMemorySize / 1MB, 1) } else { 0 }
    $ramPct     = if ($os -and $os.TotalVisibleMemorySize -gt 0) {
        [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 0)
    } else { 0 }

    $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue
    $hvciOn = ($dg -and $dg.VirtualizationBasedSecurityStatus -eq 2 -and ($dg.SecurityServicesRunning -contains 2))

    $gameDvrVal    = (Get-ItemProperty -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -ErrorAction SilentlyContinue).GameDVR_Enabled
    $appCaptureVal = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -ErrorAction SilentlyContinue).AppCaptureEnabled
    $gameDvrOn     = ($gameDvrVal -eq 1) -or ($appCaptureVal -eq 1)

    $hags = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -ErrorAction SilentlyContinue).HwSchMode

    $virtApps = @(Get-Process -Name 'com.docker.sailor', 'Docker Desktop', 'vmmemWSL', 'vmmem', 'vmware-vmx', 'VirtualBoxVM' -ErrorAction SilentlyContinue |
                  Select-Object -ExpandProperty ProcessName -Unique)
    $overlayApps = @(Get-Process -Name 'NVIDIA Overlay', 'NVIDIA Share', 'NVIDIA Broadcast', 'AMDRSServ', 'RadeonSoftware', 'Overwolf', 'obs64', 'MedalEncoder', 'RTSS' -ErrorAction SilentlyContinue |
                     Select-Object -ExpandProperty ProcessName -Unique)

    $gpuRegPath = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $dpiRegPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
    $emuPinned  = $false
    $emuDpiFix  = $false
    $targetExe  = if ($classic -and $classic.EmulatorExe) { $classic.EmulatorExe } else { $null }
    if ($targetExe) {
        if (Test-Path $gpuRegPath) {
            $gVal = (Get-ItemProperty -Path $gpuRegPath -Name $targetExe -ErrorAction SilentlyContinue).$targetExe
            if ($gVal -match 'GpuPreference=2') { $emuPinned = $true }
        }
        if (Test-Path $dpiRegPath) {
            $dVal = (Get-ItemProperty -Path $dpiRegPath -Name $targetExe -ErrorAction SilentlyContinue).$targetExe
            if ($dVal -match 'HIGHDPIAWARE') { $emuDpiFix = $true }
        }
    }

    return [PSCustomObject]@{
        IsAdmin           = (Test-IsAdmin)
        FixedNtfsDrives   = $drives
        GameLoop7Dirs     = $gl7Dirs
        GameLoop7Svc      = ($null -ne $gl7Svc)
        HasGameLoop7      = ($gl7Dirs.Count -gt 0) -or ($null -ne $gl7Svc)
        Classic           = $classic
        CachedUpgraders   = $upgraders
        NeutralizedStubs  = $stubs
        ActiveUpdaters    = $activeUpdaters
        DisabledUpdaters  = $disabledUpdaters
        ClassicInstaller  = $installer
        StoreFwBlocked    = $fwBlocked
        FirewallStatus    = $fwStatus
        LockedFolders     = $lockedCount
        TotalLockTargets  = $lockTargets.Count
        GpuProfile        = $gpuProfile
        DisplayScalingPct = $dpiPct
        Defender          = $defender
        TotalRamGb        = $totalRamGb
        RamUsedPercent    = $ramPct
        HvciEnabled       = $hvciOn
        GameDvrEnabled    = $gameDvrOn
        HagsEnabled       = ($hags -eq 2)
        VirtAppsRunning   = $virtApps
        OverlayApps       = $overlayApps
        ClassicGpuPinned  = $emuPinned
        ClassicDpiFixed   = $emuDpiFix
    }
}

# ============================================================================
# 3. DETECT-BEFORE-APPLY PLAN BUILDERS (Inspect First, Never Apply Blindly)
# ============================================================================
function Get-RemoveGameLoop7Plan {
    $runningProcs = New-Object System.Collections.Generic.List[string]
    foreach ($p in @(
        'GameLoop', 'GameLoopEmulator', 'GameLoopVm', 'GameLoopAssistant',
        'GameLoopLauncher', 'GameLoopDldSvr', 'GameLoopService',
        'GLABoxHeadless', 'GLABoxSVC', 'GameLoopVfs'
    )) {
        if (Get-Process -Name $p -ErrorAction SilentlyContinue) { $runningProcs.Add($p) }
    }

    $hasService = ($null -ne (Get-Service -Name 'GameLoopService' -ErrorAction SilentlyContinue))

    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($d in (Find-GameLoop7Installs)) { $dirs.Add($d) }
    foreach ($extra in @(
        (Join-Path $env:APPDATA 'Tencent\GameLoop'),
        (Join-Path $env:APPDATA 'Tencent\Androws'),
        (Join-Path $env:LOCALAPPDATA 'Tencent\GameLoop'),
        (Join-Path $env:LOCALAPPDATA 'Temp\Tencent\GameLoop')
    )) {
        if ($extra -and (Test-Path -LiteralPath $extra)) {
            $items = @(Get-ChildItem -LiteralPath $extra -Force -ErrorAction SilentlyContinue)
            if ($items.Count -gt 0 -and (-not $dirs.Contains($extra))) {
                $dirs.Add($extra)
            }
        }
    }

    $upgraders = @(Find-CachedSilentUpgraders)

    # Only flag shortcuts that actually point to GameLoop 7.0
    $shortcuts = New-Object System.Collections.Generic.List[string]
    $shortcutCandidates = @(
        (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'GameLoop.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'GameLoop.lnk'),
        (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'GameLoop.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'GameLoop.lnk')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    if ($shortcutCandidates.Count -gt 0) {
        $wsh = New-Object -ComObject WScript.Shell
        foreach ($lnk in $shortcutCandidates) {
            try {
                $target = $wsh.CreateShortcut($lnk).TargetPath
                if ($target -and ($target -notmatch 'TxGameAssistant') -and ($target -match 'Tencent\\GameLoop|GameLoopLauncher|GameLoop\.exe')) {
                    $shortcuts.Add($lnk)
                }
            } catch { }
        }
    }

    # Scan Uninstall keys dynamically for GameLoop 7.0 and ANY game installed under 7.0
    $regKeys = New-Object System.Collections.Generic.List[string]
    foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($sub in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $keyName  = $sub.PSChildName
            $p        = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
            $combined = "$($p.InstallLocation) $($p.UninstallString) $($p.DisplayIcon)"
            $isClassic = ($combined -match 'TxGameAssistant|AppMarket\.exe')
            $is7 = (-not $isClassic) -and (
                ($keyName -in @('GameLoop', 'TenStore-Android-Connect')) -or
                ($combined -match 'Tencent\\GameLoop|TenStore-Android-Connect')
            )
            if ($is7) { $regKeys.Add($sub.PSPath) }
        }
    }
    foreach ($rk in @('HKCU:\Software\Tencent\GameLoop', 'HKLM:\SOFTWARE\Tencent\GameLoop', 'HKLM:\SOFTWARE\WOW6432Node\Tencent\GameLoop')) {
        if (Test-Path -LiteralPath $rk) { $regKeys.Add($rk) }
    }

    $regValues = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($rpath in @('HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers', 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences')) {
        if (Test-Path $rpath) {
            $props = (Get-Item -Path $rpath).Property
            foreach ($prop in $props) {
                if ($prop -match 'Tencent\\GameLoop') {
                    $regValues.Add([PSCustomObject]@{ Path = $rpath; Name = $prop })
                }
            }
        }
    }

    $summary = New-Object System.Collections.Generic.List[string]
    if ($runningProcs.Count -gt 0) { $summary.Add("Stop $($runningProcs.Count) running 7.0 process(es): $($runningProcs -join ', ')") }
    if ($hasService)               { $summary.Add("Stop & delete Windows Service: GameLoopService") }
    foreach ($d in $dirs)          { $summary.Add("Delete 7.0 folder: $d") }
    foreach ($u in $upgraders)     { $summary.Add("Delete cached 7.0 silent upgrader: $u") }
    foreach ($s in $shortcuts)     { $summary.Add("Remove 7.0 shortcut: $s") }
    if ($regKeys.Count -gt 0)      { $summary.Add("Clean $($regKeys.Count) GameLoop 7.0 registry key(s)") }
    if ($regValues.Count -gt 0)    { $summary.Add("Clean $($regValues.Count) GameLoop 7.0 GPU/DPI registry entry(s)") }

    return [PSCustomObject]@{
        RunningProcs = $runningProcs.ToArray()
        HasService   = $hasService
        Dirs         = $dirs.ToArray()
        Upgraders    = $upgraders
        Shortcuts    = $shortcuts.ToArray()
        RegKeys      = $regKeys.ToArray()
        RegValues    = $regValues.ToArray()
        Summary      = $summary.ToArray()
        HasWork      = ($summary.Count -gt 0)
    }
}

function Get-LockUpdatesPlan {
    # Surgical emulator-update-only lock: blocks GameLoop 7.0 self-upgrade while keeping AppMarket game downloads/updates 100% online!
    $lockTargets     = Get-GameLoop7LockTargets
    $unlockedDirs    = @($lockTargets | Where-Object { -not (Test-PathWriteLocked $_) })
    $upgraders       = @(Find-CachedSilentUpgraders)
    $classic         = Find-ClassicGameLoop
    $classicUpdaters = @(Find-ActiveClassicBundledUpdaters -Classic $classic)

    $regAutoUpdateFixes = New-Object System.Collections.Generic.List[string]
    foreach ($rk in @('HKCU:\Software\Tencent\MobileGamePC', 'HKCU:\Software\Tencent\MobileGamePC\AppMarket')) {
        if (Test-Path -LiteralPath $rk) {
            $p = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
            if ($p.AutoUpdate -ne 0 -or $p.EnableAutoUpdate -ne 0) {
                $regAutoUpdateFixes.Add($rk)
            }
        }
    }

    $desktopDir   = [Environment]::GetFolderPath('Desktop')
    $shortcutPath = if ($desktopDir) { Join-Path $desktopDir 'GameLoop Classic (Direct Launch).lnk' } else { $null }
    $needShortcut = ($classic -and $classic.EmulatorExe -and $shortcutPath -and (-not (Test-Path -LiteralPath $shortcutPath)))

    $summary = New-Object System.Collections.Generic.List[string]
    if ($unlockedDirs.Count -gt 0) {
        $summary.Add("NTFS write-lock $($unlockedDirs.Count) GameLoop 7.0 destination folder(s) across all detected NTFS drives & AppData")
    }
    if ($upgraders.Count -gt 0) {
        $summary.Add("Neutralize $($upgraders.Count) cached GameLoop 7.0 silent upgrader(s) into 0-byte write/execute-denied stubs")
    }
    if ($classicUpdaters.Count -gt 0) {
        $names = ($classicUpdaters | ForEach-Object { Split-Path -Leaf $_ }) -join ', '
        $summary.Add("Disable $($classicUpdaters.Count) bundled Classic 7.0/client updater(s): $names")
    }
    if ($regAutoUpdateFixes.Count -gt 0) {
        $summary.Add("Set AutoUpdate=0 in $($regAutoUpdateFixes.Count) Classic registry key(s)")
    }
    if ($needShortcut) {
        $summary.Add("Create Direct Launch Desktop shortcut: $shortcutPath")
    }

    $hasActionableWork = ($unlockedDirs.Count -gt 0) -or ($upgraders.Count -gt 0) -or
                         ($classicUpdaters.Count -gt 0) -or ($regAutoUpdateFixes.Count -gt 0) -or
                         $needShortcut

    if ($hasActionableWork) {
        $summary.Add("[Games Stay Online] AppMarket.exe is NOT blocked — PUBG Mobile & all other game downloads/updates remain 100% working!")
    }

    return [PSCustomObject]@{
        Classic            = $classic
        UnlockedDirs       = $unlockedDirs
        Upgraders          = $upgraders
        ClassicUpdaters    = $classicUpdaters
        RegAutoUpdateFixes = $regAutoUpdateFixes.ToArray()
        NeedShortcut       = $needShortcut
        ShortcutPath       = $shortcutPath
        Summary            = $summary.ToArray()
        HasWork            = $hasActionableWork
    }
}

function Get-OptimizeWindowsPlan {
    $gpuProfile = Get-GpuProfile
    $dpiPct     = Get-DisplayScalingPercent
    $defender   = Get-DefenderState
    $exes       = Get-AllGameLoopExecutables
    $classic    = Find-ClassicGameLoop
    $gl7Dirs    = Find-GameLoop7Installs

    $gpuReg = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $dpiReg = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'

    $gpuToPin = New-Object System.Collections.Generic.List[string]
    $dpiToFix = New-Object System.Collections.Generic.List[PSCustomObject]

    foreach ($exe in $exes) {
        if ($gpuProfile.HasDiscreteGpu) {
            $curGpu = if (Test-Path $gpuReg) { (Get-ItemProperty -Path $gpuReg -Name $exe -ErrorAction SilentlyContinue).$exe } else { $null }
            if ($curGpu -notmatch 'GpuPreference=2') {
                $gpuToPin.Add($exe)
            }
        }

        $curDpi      = if (Test-Path $dpiReg) { (Get-ItemProperty -Path $dpiReg -Name $exe -ErrorAction SilentlyContinue).$exe } else { $null }
        $needHighDpi = ($dpiPct -gt 100) -and ($curDpi -notmatch 'HIGHDPIAWARE')
        $needNoFso   = ($curDpi -notmatch 'DISABLEDXMAXIMIZEDWINDOWEDMODE')
        if ($needHighDpi -or $needNoFso) {
            $tokens = New-Object System.Collections.Generic.List[string]
            if ($curDpi) {
                foreach ($tok in ($curDpi -split '\s+')) {
                    if ($tok -and $tok -ne '~' -and (-not $tokens.Contains($tok))) { $tokens.Add($tok) }
                }
            }
            if ($needHighDpi -and (-not $tokens.Contains('HIGHDPIAWARE'))) { $tokens.Add('HIGHDPIAWARE') }
            if ($needNoFso -and (-not $tokens.Contains('DISABLEDXMAXIMIZEDWINDOWEDMODE'))) { $tokens.Add('DISABLEDXMAXIMIZEDWINDOWEDMODE') }
            $newVal = '~ ' + ($tokens -join ' ')
            $dpiToFix.Add([PSCustomObject]@{ Exe = $exe; NewValue = $newVal; AddedHighDpi = $needHighDpi; AddedNoFso = $needNoFso })
        }
    }

    $gameDvrVal     = (Get-ItemProperty -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -ErrorAction SilentlyContinue).GameDVR_Enabled
    $appCaptureVal  = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -ErrorAction SilentlyContinue).AppCaptureEnabled
    $needDisableDvr = ($gameDvrVal -ne 0) -or ($appCaptureVal -ne 0)

    $missingDefPaths = New-Object System.Collections.Generic.List[string]
    $missingDefProcs = New-Object System.Collections.Generic.List[string]
    if ($defender.ServiceRunning) {
        $candPaths = New-Object System.Collections.Generic.List[string]
        if ($classic) { $candPaths.Add($classic.Root) }
        foreach ($td in (Find-TxGameDownloadDirs)) { $candPaths.Add($td) }
        foreach ($d in $gl7Dirs) { $candPaths.Add($d) }

        foreach ($p in ($candPaths | Select-Object -Unique)) {
            $already = $false
            foreach ($existing in $defender.ExclusionPaths) {
                if ($existing -and ($existing.TrimEnd('\') -ieq $p.TrimEnd('\'))) { $already = $true; break }
            }
            if (-not $already) { $missingDefPaths.Add($p) }
        }

        $candProcs = New-Object System.Collections.Generic.List[string]
        if ($classic) {
            foreach ($pn in @('AndroidEmulatorEn.exe', 'AndroidEmulatorEx.exe', 'AndroidEmulator.exe', 'aow_exe.exe')) { $candProcs.Add($pn) }
        }
        if ($gl7Dirs.Count -gt 0) {
            foreach ($pn in @('GameLoopVm.exe', 'GameLoopEmulator.exe')) { $candProcs.Add($pn) }
        }
        foreach ($pn in ($candProcs | Select-Object -Unique)) {
            $already = $false
            foreach ($existing in $defender.ExclusionProcs) {
                if ($existing -and ($existing -ieq $pn)) { $already = $true; break }
            }
            if (-not $already) { $missingDefProcs.Add($pn) }
        }
    }

    $summary = New-Object System.Collections.Generic.List[string]
    if ($exes.Count -eq 0) {
        $summary.Add("[Notice] No installed GameLoop executables detected yet (GPU/DPI/folder tuning skipped until installed)")
    }
    if ($gpuToPin.Count -gt 0) {
        $summary.Add("Pin $($gpuToPin.Count) detected GameLoop executable(s) to High-Performance GPU ($($gpuProfile.DiscreteGpus -join ', '))")
    }
    if ($dpiToFix.Count -gt 0) {
        $dpiLabel = if ($dpiPct -gt 100) { "High-DPI blur fix (${dpiPct}% scaling detected) + Disable Fullscreen Optimizations" } else { "Disable Fullscreen Optimizations (DPI is 100%)" }
        $summary.Add("Apply $dpiLabel to $($dpiToFix.Count) executable(s)")
    }
    if ($needDisableDvr) {
        $summary.Add("Disable Xbox Game DVR background capture hook (currently enabled/default)")
    }
    if ($missingDefPaths.Count -gt 0 -or $missingDefProcs.Count -gt 0) {
        $summary.Add("Add Windows Defender exclusions for $($missingDefPaths.Count) detected folder(s) & $($missingDefProcs.Count) emulator process(es)")
    }

    $hasWork = ($gpuToPin.Count -gt 0) -or ($dpiToFix.Count -gt 0) -or $needDisableDvr -or
               ($missingDefPaths.Count -gt 0) -or ($missingDefProcs.Count -gt 0)

    return [PSCustomObject]@{
        GpuProfile      = $gpuProfile
        DisplayScaling  = $dpiPct
        Defender        = $defender
        DetectedExes    = $exes
        GpuToPin        = $gpuToPin.ToArray()
        DpiToFix        = $dpiToFix.ToArray()
        NeedDisableDvr  = $needDisableDvr
        MissingDefPaths = $missingDefPaths.ToArray()
        MissingDefProcs = $missingDefProcs.ToArray()
        Summary         = $summary.ToArray()
        HasWork         = $hasWork
    }
}

function Get-UnblockAllPlan {
    $fwRules          = @(Get-NetFirewallRule -DisplayName "${script:FwRulePrefix}*" -ErrorAction SilentlyContinue)
    $lockedDirs       = @(Get-GameLoop7LockTargets | Where-Object { Test-PathWriteLocked $_ })
    $lockedStubs      = @(Find-NeutralizedUpgraderStubs)
    $classic          = Find-ClassicGameLoop
    $disabledUpdaters = @(Find-DisabledClassicBundledUpdaters -Classic $classic)

    $summary = New-Object System.Collections.Generic.List[string]
    if ($fwRules.Count -gt 0)          { $summary.Add("Remove $($fwRules.Count) GameLoop Doctor Firewall rule(s)") }
    if ($lockedDirs.Count -gt 0)       { $summary.Add("Unlock $($lockedDirs.Count) NTFS write-denied placeholder folder(s)") }
    if ($lockedStubs.Count -gt 0)      { $summary.Add("Remove $($lockedStubs.Count) neutralized 0-byte silent upgrader stub(s)") }
    if ($disabledUpdaters.Count -gt 0) { $summary.Add("Restore $($disabledUpdaters.Count) renamed Classic updater binary(s)") }

    return [PSCustomObject]@{
        FwRules          = $fwRules
        LockedDirs       = $lockedDirs
        LockedStubs      = $lockedStubs
        DisabledUpdaters = $disabledUpdaters
        Summary          = $summary.ToArray()
        HasWork          = ($summary.Count -gt 0)
    }
}

# ============================================================================
# 4. ACTION FUNCTIONS (Execute Only Detected Changes, Support -DryRun)
# ============================================================================
function Invoke-RemoveGameLoop7 {
    param(
        [switch]$DryRunMode,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )

    $plan = Get-RemoveGameLoop7Plan
    if (-not $plan.HasWork) {
        & $Log "[OK] GameLoop 7.0 was not detected on this PC — nothing to remove."
        return $true
    }

    if ($DryRunMode) {
        & $Log "=== [DRY RUN] GameLoop 7.0 Items Detected For Removal ==="
        foreach ($line in $plan.Summary) { & $Log "  [WOULD DO] $line" }
        return $true
    }

    if (-not (Test-IsAdmin)) {
        & $Log "[ERROR] Administrator privileges are required to remove GameLoop 7.0."
        return $false
    }

    & $Log "=== Removing Detected GameLoop 7.0 ('Androws') Components ==="

    foreach ($p in $plan.RunningProcs) {
        Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        & $Log "  Stopped process: $p"
    }

    if ($plan.HasService) {
        Stop-Service -Name 'GameLoopService' -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        & sc.exe delete GameLoopService | Out-Null
        & $Log "  Deleted Windows Service: GameLoopService"
    }
    if ($plan.RunningProcs.Count -gt 0 -or $plan.HasService) { Start-Sleep -Seconds 1 }

    foreach ($d in $plan.Dirs) {
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

    foreach ($u in $plan.Upgraders) {
        & icacls.exe $u /remove:d "*S-1-1-0" /C /Q 2>&1 | Out-Null
        Remove-Item -LiteralPath $u -Force -ErrorAction SilentlyContinue
        & $Log "  Deleted cached 7.0 silent upgrader: $u"
    }

    foreach ($lnk in $plan.Shortcuts) {
        Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
        & $Log "  Removed 7.0 shortcut: $lnk"
    }

    foreach ($rk in $plan.RegKeys) {
        if (Test-Path -LiteralPath $rk) {
            Remove-Item -LiteralPath $rk -Recurse -Force -ErrorAction SilentlyContinue
            & $Log "  Removed registry key: $rk"
        }
    }

    foreach ($rv in $plan.RegValues) {
        Remove-ItemProperty -Path $rv.Path -Name $rv.Name -ErrorAction SilentlyContinue
        & $Log "  Cleaned 7.0 registry value: $($rv.Name)"
    }

    & $Log "[OK] Detected GameLoop 7.0 components removed! Classic installer & caches preserved."
    return $true
}

function Invoke-LockUpdates {
    param(
        [switch]$DryRunMode,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )

    $plan = Get-LockUpdatesPlan
    if (-not $plan.HasWork) {
        & $Log "[OK] All Anti-GameLoop-7.0 emulator update blocks are already active (and game downloads stay 100% online)!"
        return $true
    }

    if ($DryRunMode) {
        & $Log "=== [DRY RUN] Surgical Anti-GameLoop-7.0 Shield (Games Stay Online) ==="
        foreach ($line in $plan.Summary) { & $Log "  [WOULD DO] $line" }
        return $true
    }

    if (-not (Test-IsAdmin)) {
        & $Log "[ERROR] Administrator privileges are required to lock out GameLoop 7.0 updates."
        return $false
    }

    & $Log "=== Applying Surgical Anti-GameLoop-7.0 Shield (Game Downloads Stay Online!) ==="

    # Layer 1: NTFS Write-Deny on all GameLoop 7.0 install, data, and database folders across every fixed NTFS drive
    foreach ($t in $plan.UnlockedDirs) {
        $drv = [System.IO.Path]::GetPathRoot($t)
        if (-not (Test-Path -LiteralPath $drv)) { continue }
        if (Test-Path -LiteralPath $t) {
            & icacls.exe $t /remove:d "*S-1-1-0" /T /C /Q 2>&1 | Out-Null
            Get-ChildItem -LiteralPath $t -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            New-Item -ItemType Directory -Path $t -Force | Out-Null
        }
        & icacls.exe $t /deny "*S-1-1-0:(OI)(CI)(W,WD,AD,DC)" /C /Q 2>&1 | Out-Null
        & $Log "  [Layer 1] NTFS Write-Locked 7.0 target: $t"
    }

    # Layer 2a: Neutralize cached com_tencent_gameloop_*.exe silent upgraders into 0-byte Write+Execute-Denied stubs
    foreach ($u in $plan.Upgraders) {
        try {
            & icacls.exe $u /remove:d "*S-1-1-0" /C /Q 2>&1 | Out-Null
            Remove-Item -LiteralPath $u -Force -ErrorAction Stop
            [System.IO.File]::WriteAllBytes($u, [byte[]]@())
            & icacls.exe $u /deny "*S-1-1-0:(W,WA,WEA,DC,X)" /C /Q 2>&1 | Out-Null
            & $Log "  [Layer 2] Neutralized silent upgrader into 0-byte locked stub: $(Split-Path -Leaf $u)"
        } catch {
            & $Log "  [WARN] Could not neutralize $u : $($_.Exception.Message)"
        }
    }

    # Layer 2b: Disable Classic's bundled 7.0 / client updater binaries (leaves AppMarket.exe & GameDownload.exe untouched!)
    foreach ($u in $plan.ClassicUpdaters) {
        $newName = "$([System.IO.Path]::GetFileName($u)).disabled"
        Rename-Item -LiteralPath $u -NewName $newName -Force -ErrorAction SilentlyContinue
        & $Log "  [Layer 2] Disabled bundled emulator updater: $u"
    }

    # Layer 2c: Disable Classic AutoUpdate registry flags
    foreach ($rk in $plan.RegAutoUpdateFixes) {
        New-ItemProperty -Path $rk -Name 'AutoUpdate' -Value 0 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $rk -Name 'EnableAutoUpdate' -Value 0 -PropertyType DWord -Force | Out-Null
        & $Log "  [Layer 2] Set AutoUpdate=0 in: $rk"
    }

    # Layer 3: Direct Launch Desktop shortcut (optional convenience; Store remains 100% online for game downloads/updates!)
    if ($plan.NeedShortcut) {
        $wsh = New-Object -ComObject WScript.Shell
        $sc  = $wsh.CreateShortcut($plan.ShortcutPath)
        $sc.TargetPath       = $plan.Classic.EmulatorExe
        $sc.Arguments        = '-vm 100'
        $sc.WorkingDirectory = Split-Path -Parent $plan.Classic.EmulatorExe
        $sc.Description      = 'Launch Classic GameLoop Emulator directly without opening Store'
        $sc.Save()
        & $Log "  [Layer 3] Created Direct Launch Desktop shortcut: $($plan.ShortcutPath)"
    }

    & $Log "[OK] GameLoop 7.0 emulator upgrades are BLOCKED! Game downloads & game updates in AppMarket remain 100% online."
    return $true
}

function Invoke-StrictBlockStore {
    param(
        [switch]$DryRunMode,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )
    $classic = Find-ClassicGameLoop
    if (-not $classic) {
        & $Log "[INFO] Classic GameLoop (TxGameAssistant) was not detected — nothing to block."
        return $true
    }
    if (-not $classic.HasEngineUI) {
        & $Log "[SMART GUARD] Classic emulator UI engine is not installed yet (games are still downloading). Refusing to block AppMarket.exe so your game downloads succeed!"
        return $true
    }
    $existing = Get-NetFirewallRule -DisplayName "${script:FwRulePrefix}AppMarket" -ErrorAction SilentlyContinue
    if ($existing -and $existing.Enabled -eq 'True') {
        & $Log "[OK] Strict Mode Firewall block on AppMarket.exe is already active."
        return $true
    }
    if ($DryRunMode) {
        & $Log "=== [DRY RUN] Optional Strict Store Firewall Block ==="
        & $Log "  [WOULD DO] Block Outbound Firewall traffic for $($classic.AppMarketExe) (note: you must click 'Allow Store' later to download/update games)"
        return $true
    }
    if (-not (Test-IsAdmin)) {
        & $Log "[ERROR] Administrator privileges are required to modify Windows Firewall."
        return $false
    }
    Get-NetFirewallRule -DisplayName "${script:FwRulePrefix}*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule `
        -DisplayName "${script:FwRulePrefix}AppMarket" `
        -Direction Outbound `
        -Action Block `
        -Program $classic.AppMarketExe `
        -Profile Any `
        -Description "Optional Strict Mode: blocks Classic GameLoop AppMarket outbound traffic. Emulator & games remain online; click Allow Store to download/update games." | Out-Null
    & $Log "[OK] Strict Mode enabled: AppMarket.exe blocked outbound. Emulator & already-installed games stay 100% online."
    & $Log "     Click 'Allow Store' whenever you want to download a new game or install a major APK update."
    return $true
}

function Invoke-AllowStore {
    param(
        [switch]$DryRunMode,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )
    $rules = @(Get-NetFirewallRule -DisplayName "${script:FwRulePrefix}AppMarket" -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' })
    if ($rules.Count -eq 0) {
        & $Log "[INFO] AppMarket.exe is already online — game downloads & game updates are allowed!"
        return $true
    }
    if ($DryRunMode) {
        & $Log "=== [DRY RUN] Re-Allow GameLoop Store Downloads ==="
        & $Log "  [WOULD DO] Remove/disable GameLoop Doctor's AppMarket.exe Firewall block (NTFS 7.0 lockdown & updater blocks remain active)"
        return $true
    }
    if (-not (Test-IsAdmin)) {
        & $Log "[ERROR] Administrator privileges are required to modify Windows Firewall."
        return $false
    }
    $rules | Remove-NetFirewallRule
    & $Log "[OK] AppMarket.exe is now ONLINE — game downloads & game updates work normally!"
    & $Log "     Your NTFS 7.0 lockdown and bundled updater blocks REMAIN ACTIVE so GameLoop 7.0 still cannot install."
    return $true
}

function Invoke-OptimizeWindows {
    param(
        [switch]$DryRunMode,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )

    $plan = Get-OptimizeWindowsPlan
    if (-not $plan.HasWork) {
        if ($plan.DetectedExes.Count -eq 0) {
            & $Log "[INFO] No installed GameLoop executables detected yet and Game DVR is already OFF — nothing to change."
        } else {
            & $Log "[OK] All detected Windows optimizations are already applied on this PC — nothing to change!"
        }
        return $true
    }

    if ($DryRunMode) {
        & $Log "=== [DRY RUN] Detected Windows Optimizations To Apply ==="
        foreach ($line in $plan.Summary) { & $Log "  [WOULD DO] $line" }
        return $true
    }

    & $Log "=== Applying Detected Windows Performance Optimizations ==="

    $gpuReg = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $dpiReg = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'

    if ($plan.GpuToPin.Count -gt 0) {
        if (-not (Test-Path $gpuReg)) { New-Item -Path $gpuReg -Force | Out-Null }
        foreach ($exe in $plan.GpuToPin) {
            Set-ItemProperty -Path $gpuReg -Name $exe -Value 'GpuPreference=2;' -Type String
            & $Log "  Pinned High-Perf GPU ($($plan.GpuProfile.DiscreteGpus -join ', ')): $exe"
        }
    } elseif ($plan.DetectedExes.Count -gt 0 -and (-not $plan.GpuProfile.HasDiscreteGpu)) {
        & $Log "  [SKIP] Discrete GPU pinning skipped (no discrete GPU detected on this PC)."
    }

    if ($plan.DpiToFix.Count -gt 0) {
        if (-not (Test-Path $dpiReg)) { New-Item -Path $dpiReg -Force | Out-Null }
        foreach ($item in $plan.DpiToFix) {
            Set-ItemProperty -Path $dpiReg -Name $item.Exe -Value $item.NewValue -Type String
            & $Log "  Set AppCompat ($($item.NewValue)): $($item.Exe)"
        }
    }

    if ($plan.NeedDisableDvr) {
        if (-not (Test-Path 'HKCU:\System\GameConfigStore')) { New-Item -Path 'HKCU:\System\GameConfigStore' -Force | Out-Null }
        Set-ItemProperty -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 0 -Type DWord
        if (-not (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR')) { New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Force | Out-Null }
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -Value 0 -Type DWord
        & $Log "  Disabled Xbox Game DVR background capture hook."
    }

    if ($plan.MissingDefPaths.Count -gt 0 -or $plan.MissingDefProcs.Count -gt 0) {
        if (Test-IsAdmin) {
            try {
                if ($plan.MissingDefPaths.Count -gt 0) {
                    Add-MpPreference -ExclusionPath $plan.MissingDefPaths -ErrorAction Stop
                    & $Log "  Added Windows Defender folder exclusions: $($plan.MissingDefPaths -join ', ')"
                }
                if ($plan.MissingDefProcs.Count -gt 0) {
                    Add-MpPreference -ExclusionProcess $plan.MissingDefProcs -ErrorAction Stop
                    & $Log "  Added Windows Defender process exclusions: $($plan.MissingDefProcs -join ', ')"
                }
            } catch {
                & $Log "  [WARN] Windows Defender exclusions skipped (may be managed by third-party AV or Tamper Protection): $($_.Exception.Message)"
            }
        } else {
            & $Log "  [INFO] Run as Administrator to also add Windows Defender exclusions."
        }
    } elseif (-not $plan.Defender.ServiceRunning) {
        & $Log "  [SKIP] Windows Defender service is not active on this PC (skipped exclusions)."
    }

    & $Log "[OK] Detected Windows optimizations applied!"
    return $true
}

function Invoke-UnblockAll {
    param(
        [switch]$DryRunMode,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )

    $plan = Get-UnblockAllPlan
    if (-not $plan.HasWork) {
        & $Log "[OK] No active GameLoop Doctor blocks found on this PC — nothing to undo."
        return $true
    }

    if ($DryRunMode) {
        & $Log "=== [DRY RUN] GameLoop Doctor Blocks Detected To Reverse ==="
        foreach ($line in $plan.Summary) { & $Log "  [WOULD DO] $line" }
        return $true
    }

    if (-not (Test-IsAdmin)) {
        & $Log "[ERROR] Administrator privileges are required to undo blocks."
        return $false
    }

    & $Log "=== Reversing Active GameLoop Doctor Blocks ==="
    if ($plan.FwRules.Count -gt 0) {
        $plan.FwRules | Remove-NetFirewallRule
        & $Log "  Removed $($plan.FwRules.Count) Firewall rule(s)."
    }

    foreach ($t in $plan.LockedDirs) {
        if (Test-Path -LiteralPath $t) {
            & icacls.exe $t /remove:d "*S-1-1-0" /C /Q 2>&1 | Out-Null
            $items = @(Get-ChildItem -LiteralPath $t -Force -ErrorAction SilentlyContinue)
            if ($items.Count -eq 0) {
                Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue
            }
            & $Log "  Unlocked folder: $t"
        }
    }

    foreach ($s in $plan.LockedStubs) {
        if (Test-Path -LiteralPath $s) {
            & icacls.exe $s /remove:d "*S-1-1-0" /C /Q 2>&1 | Out-Null
            Remove-Item -LiteralPath $s -Force -ErrorAction SilentlyContinue
            & $Log "  Removed neutralized upgrader stub: $(Split-Path -Leaf $s)"
        }
    }

    foreach ($p in $plan.DisabledUpdaters) {
        $orig = [System.IO.Path]::GetFileName($p) -replace '\.disabled$', ''
        Rename-Item -LiteralPath $p -NewName $orig -Force -ErrorAction SilentlyContinue
        & $Log "  Restored bundled updater: $orig"
    }

    & $Log "[OK] All detected GameLoop Doctor blocks cleanly reversed."
    return $true
}

# ============================================================================
# 5. HEADLESS CLI EXECUTION MODE
# ============================================================================
if ($isCliMode) {
    if ($Diagnose) {
        $d = Get-Diagnostics
        Write-Host "================ GameLoop Doctor v$($script:AppVersion) Diagnostics ================" -ForegroundColor Cyan
        Write-Host ("  Admin Rights        : {0}" -f $d.IsAdmin)
        Write-Host ("  Fixed NTFS Drives   : {0}" -f ($d.FixedNtfsDrives -join ', '))
        Write-Host ("  GameLoop 7.0 Found  : {0} ({1})" -f $d.HasGameLoop7, ($(if ($d.GameLoop7Dirs.Count) { $d.GameLoop7Dirs -join ', ' } else { 'None' })))
        Write-Host ("  Classic GameLoop    : {0}" -f $(if ($d.Classic) { "$($d.Classic.Root) (EngineUI=$($d.Classic.HasEngineUI))" } else { 'Not Installed' }))
        Write-Host ("  Local Classic Setup : {0}" -f $(if ($d.ClassicInstaller) { $d.ClassicInstaller } else { 'Not found in Downloads' }))
        Write-Host ("  Active 7.0 Upgraders: {0} (Neutralized Stubs: {1})" -f $d.CachedUpgraders.Count, $d.NeutralizedStubs.Count)
        Write-Host ("  Bundled Updaters    : {0} active / {1} disabled" -f $d.ActiveUpdaters.Count, $d.DisabledUpdaters.Count)
        Write-Host ("  NTFS 7.0 Lockdown   : {0}/{1} targets locked" -f $d.LockedFolders, $d.TotalLockTargets)
        Write-Host ("  Game Store Network  : {0}" -f $d.FirewallStatus)
        Write-Host ("  Detected GPUs       : {0} (Discrete={1}, Hybrid={2})" -f (($d.GpuProfile.AllGpus -join ' | '), $d.GpuProfile.HasDiscreteGpu, $d.GpuProfile.IsHybridDualGpu))
        Write-Host ("  Display DPI Scaling : {0}%" -f $d.DisplayScalingPct)
        Write-Host ("  Classic GPU Pinned  : {0}" -f $d.ClassicGpuPinned)
        Write-Host ("  Windows Defender    : {0}" -f $(if ($d.Defender.ServiceRunning) { 'Active' } else { 'Inactive / 3rd-party AV' }))
        Write-Host ("  RAM                 : {0}% used of {1} GB" -f $d.RamUsedPercent, $d.TotalRamGb)
        Write-Host ("  Win11 HVCI (VBS)    : {0}" -f $(if ($d.HvciEnabled) { 'ON (may add VM stutter)' } else { 'OFF (Good)' }))
        Write-Host ("  Xbox Game DVR       : {0}" -f $(if ($d.GameDvrEnabled) { 'ON (recommend OFF)' } else { 'OFF (Good)' }))
        Write-Host ("  HAGS                : {0}" -f $(if ($d.HagsEnabled) { 'ON' } else { 'OFF' }))
        Write-Host ("  VM/Container Apps   : {0}" -f $(if ($d.VirtAppsRunning.Count) { $d.VirtAppsRunning -join ', ' } else { 'None' }))
        Write-Host ("  Overlay/Capture Apps: {0}" -f $(if ($d.OverlayApps.Count) { $d.OverlayApps -join ', ' } else { 'None' }))
    }
    if ($RemoveGameLoop7)  { Invoke-RemoveGameLoop7  -DryRunMode:$DryRun | Out-Null }
    if ($LockUpdates)      { Invoke-LockUpdates      -DryRunMode:$DryRun | Out-Null }
    if ($StrictBlockStore) { Invoke-StrictBlockStore -DryRunMode:$DryRun | Out-Null }
    if ($AllowStore)       { Invoke-AllowStore       -DryRunMode:$DryRun | Out-Null }
    if ($OptimizeWindows)  { Invoke-OptimizeWindows  -DryRunMode:$DryRun | Out-Null }
    if ($UnblockAll)       { Invoke-UnblockAll       -DryRunMode:$DryRun | Out-Null }
    exit 0
}

# ============================================================================
# 6. NATIVE WINDOWS WPF DESKTOP APP (Zero Dependencies — Built into Windows!)
# ============================================================================
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="GameLoop Doctor v1.0 - Classic Restore, Anti-7.0 Shield &amp; Lag Optimizer"
        Height="750" Width="980" MinHeight="660" MinWidth="870"
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
                <TextBlock Text="Detect-First Tool • Blocks 7.0 Emulator Upgrades While Keeping Game Downloads &amp; Updates Online (100% Anti-Cheat Safe)"
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
                    <TextBlock Text="ANTI-7.0 EMULATOR SHIELD" FontSize="11" FontWeight="Bold" Foreground="#34D399"/>
                    <TextBlock x:Name="TxtShield" Text="Scanning..." FontSize="14" FontWeight="SemiBold" Margin="0,6,0,2" TextWrapping="Wrap"/>
                    <TextBlock x:Name="TxtShieldSub" Text="" FontSize="11.5" Foreground="#94A3B8" TextWrapping="Wrap"/>
                </StackPanel>
            </Border>

            <Border Grid.Column="4" Style="{StaticResource Card}" Margin="0">
                <StackPanel>
                    <TextBlock Text="LAG &amp; HARDWARE HEALTH" FontSize="11" FontWeight="Bold" Foreground="#FBBF24"/>
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
                        <TextBlock Text="1. Restore Classic GameLoop &amp; Block 7.0 Upgrades" FontSize="15" FontWeight="Bold" Foreground="#F1F5F9" Margin="0,0,0,8"/>

                        <TextBlock Text="Step 1 — Detect &amp; remove GameLoop 7.0 ('Androws'), GameLoopService, locked folders, and cached silent-upgraders (shows preview first):"
                                   FontSize="12" Foreground="#CBD5E1" TextWrapping="Wrap" Margin="0,0,0,6"/>
                        <WrapPanel>
                            <Button x:Name="BtnRemove7" Content="Remove GameLoop 7.0" Style="{StaticResource ActionBtn}" Background="#DC2626"/>
                            <Button x:Name="BtnLaunchClassic" Content="Launch Classic Installer" Style="{StaticResource ActionBtn}" Background="#0284C7"/>
                        </WrapPanel>

                        <Separator Background="#2A3148" Margin="0,6,0,10"/>

                        <TextBlock Text="Step 2 — Block GameLoop 7.0 emulator upgrades ONLY (PUBG Mobile &amp; all game downloads/updates stay 100% working!):"
                                   FontSize="12" Foreground="#CBD5E1" TextWrapping="Wrap" Margin="0,0,0,6"/>
                        <WrapPanel>
                            <Button x:Name="BtnLockUpdates" Content="Lock Out 7.0 Updates (Games Online)" Style="{StaticResource ActionBtn}" Background="#059669"/>
                            <Button x:Name="BtnToggleStrict" Content="Optional: Block Store Traffic" Style="{StaticResource ActionBtn}" Background="#D97706"/>
                        </WrapPanel>

                        <TextBlock Text="How it works: Locks every GameLoop 7.0 install/DB target across all fixed NTFS drives, disables bundled 7.0 updaters (AndrowsInstaller, pcyyb_installer, tupdate), and neutralizes cached silent upgraders — WITHOUT blocking AppMarket.exe so game downloads &amp; updates work anytime!"
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

                        <TextBlock Text="Scans your hardware first and applies only what's needed: Discrete GPU pin (if dGPU present), DPI scaling blur fix, Fullscreen Optimizations off, Xbox Game DVR off, and Defender exclusions (if Defender is active):"
                                   FontSize="12" Foreground="#CBD5E1" TextWrapping="Wrap" Margin="0,0,0,8"/>
                        <WrapPanel>
                            <Button x:Name="BtnOptimize" Content="Apply Detected Performance Fixes" Style="{StaticResource ActionBtn}" Background="#7C3AED"/>
                            <Button x:Name="BtnOpenSecurity" Content="Open Core Isolation (HVCI)" Style="{StaticResource ActionBtn}" Background="#334155"/>
                        </WrapPanel>

                        <Separator Background="#2A3148" Margin="0,6,0,10"/>

                        <TextBlock Text="System Lag Checklist (Auto-Detected on This PC):" FontSize="12.5" FontWeight="SemiBold" Foreground="#E2E8F0" Margin="0,0,0,4"/>
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
$BtnToggleStrict  = $window.FindName('BtnToggleStrict')
$BtnUnblockAll    = $window.FindName('BtnUnblockAll')
$BtnOptimize      = $window.FindName('BtnOptimize')
$BtnOpenSecurity  = $window.FindName('BtnOpenSecurity')
$BtnCopyLog       = $window.FindName('BtnCopyLog')

$script:LastDiag = $null

$WriteLog = {
    param([string]$Message)
    $ts = (Get-Date).ToString('HH:mm:ss')
    $TxtLog.AppendText("[$ts] $Message`r`n")
    $TxtLog.ScrollToEnd()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
}

$RefreshUI = {
    $d = Get-Diagnostics
    $script:LastDiag = $d

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

    # Card 2: Surgical Shield (Green WITHOUT needing AppMarket Firewall block!)
    $allTargetsLocked = ($d.TotalLockTargets -gt 0) -and ($d.LockedFolders -eq $d.TotalLockTargets)
    $updatersClean    = ($d.CachedUpgraders.Count -eq 0) -and ($d.ActiveUpdaters.Count -eq 0)
    if ($allTargetsLocked -and $updatersClean) {
        if ($d.StoreFwBlocked) {
            $TxtShield.Text = "Protected (Strict Store Block)"
            $TxtShield.Foreground = '#4ADE80'
        } else {
            $TxtShield.Text = "Protected (Games Online)"
            $TxtShield.Foreground = '#4ADE80'
        }
    } elseif ($d.LockedFolders -gt 0) {
        $TxtShield.Text = "Partially Protected"
        $TxtShield.Foreground = '#FBBF24'
    } else {
        $TxtShield.Text = "Unprotected (7.0 Can Auto-Install)"
        $TxtShield.Foreground = '#F87171'
    }
    $TxtShieldSub.Text = "NTFS Locks: $($d.LockedFolders)/$($d.TotalLockTargets) | Active Updaters: $($d.ActiveUpdaters.Count + $d.CachedUpgraders.Count)`nStore: $($d.FirewallStatus)"

    # Update Strict Mode toggle button text dynamically
    if ($d.StoreFwBlocked) {
        $BtnToggleStrict.Content    = 'Re-Allow Store Game Downloads'
        $BtnToggleStrict.Background = '#0284C7'
    } else {
        $BtnToggleStrict.Content    = 'Optional: Strict Block Store'
        $BtnToggleStrict.Background = '#D97706'
    }

    # Card 3: Generic Performance & Hardware Advisor
    $issues = New-Object System.Collections.Generic.List[string]
    if ($d.GameDvrEnabled)  { $issues.Add("Xbox Game DVR is ON (adds frame spikes)") }
    if ($d.HvciEnabled)     { $issues.Add("Windows Memory Integrity (HVCI) is ON (adds virtualization overhead)") }
    if ($d.VirtAppsRunning.Count -gt 0) { $issues.Add("Other VM/container app running ($($d.VirtAppsRunning -join ', ')) — close before gaming") }
    if ($d.RamUsedPercent -ge 75) { $issues.Add("High host RAM usage ($($d.RamUsedPercent)% of $($d.TotalRamGb) GB) — close heavy background apps/browsers") }
    if ($d.OverlayApps.Count -gt 0) { $issues.Add("Background GPU/capture overlay running: $($d.OverlayApps -join ', ')") }
    if ($d.Classic -and $d.Classic.HasEngineUI -and $d.GpuProfile.HasDiscreteGpu -and (-not $d.ClassicGpuPinned)) {
        $issues.Add("Classic emulator not yet pinned to discrete GPU ($($d.GpuProfile.DiscreteGpus -join ', '))")
    }
    if ($d.Classic -and $d.Classic.HasEngineUI -and $d.DisplayScalingPct -gt 100 -and (-not $d.ClassicDpiFixed)) {
        $issues.Add("Display scaling is $($d.DisplayScalingPct)% — apply High-DPI fix to prevent blurry rendering")
    }

    if ($issues.Count -eq 0) {
        $TxtPerf.Text = "Optimal"
        $TxtPerf.Foreground = '#4ADE80'
        $TxtPerfSub.Text = "RAM: $($d.RamUsedPercent)% | DPI: $($d.DisplayScalingPct)% | Clean"
        $TxtAdvisor.Text = "• All core checks look great on this PC!`n• In Classic GameLoop Settings -> Game, set Gaming Resolution to Ultra HD 2K.`n• If using a 1000 Hz+ gaming mouse and camera stutters, lower mouse polling rate to 250-500 Hz."
    } else {
        $TxtPerf.Text = "$($issues.Count) Lag Factor(s) Found"
        $TxtPerf.Foreground = '#FBBF24'
        $TxtPerfSub.Text = "RAM: $($d.RamUsedPercent)% | DPI: $($d.DisplayScalingPct)% | GPUs: $($d.GpuProfile.AllGpus.Count)"
        $TxtAdvisor.Text = ($issues | ForEach-Object { "• $_" }) -join "`n"
    }
}

$BtnRefresh.Add_Click({
    & $WriteLog "Rescanning system..."
    & $RefreshUI
    & $WriteLog "Scan complete."
})

$BtnRemove7.Add_Click({
    $plan = Get-RemoveGameLoop7Plan
    if (-not $plan.HasWork) {
        & $WriteLog "[OK] GameLoop 7.0 was not detected on this PC — nothing to remove."
        [System.Windows.MessageBox]::Show("GameLoop 7.0 ('Androws') was not detected on this PC. Nothing was changed.", "Nothing To Remove", 'OK', 'Information') | Out-Null
        return
    }
    $preview = ($plan.Summary | ForEach-Object { "• $_" }) -join "`n"
    $ans = [System.Windows.MessageBox]::Show(
        "Detected the following GameLoop 7.0 items on this PC:`n`n$preview`n`nYour Classic GLP_installer and cached classic packages will NOT be touched.`n`nProceed with removal?",
        "Confirm Remove GameLoop 7.0", 'YesNo', 'Warning')
    if ($ans -eq 'Yes') {
        Invoke-RemoveGameLoop7 -Log $WriteLog | Out-Null
        & $RefreshUI
    }
})

$BtnLaunchClassic.Add_Click({
    $inst = Find-ClassicInstaller
    if ($inst) {
        $ans = [System.Windows.MessageBox]::Show(
            "Found local GameLoop installer:`n$inst`n`nLaunch this installer now?",
            "Launch Detected Installer", 'YesNo', 'Question')
        if ($ans -eq 'Yes') {
            & $WriteLog "Launching detected local installer: $inst"
            Start-Process -FilePath $inst
        }
    } else {
        & $WriteLog "No local GLP_installer*.exe found in Downloads/Desktop. Opening gameloop.com..."
        Start-Process "https://www.gameloop.com/"
    }
})

$BtnLockUpdates.Add_Click({
    $plan = Get-LockUpdatesPlan
    if (-not $plan.HasWork) {
        & $WriteLog "[OK] All Anti-7.0 emulator update blocks are already active (game downloads & updates remain online)."
        [System.Windows.MessageBox]::Show("All Anti-GameLoop-7.0 protections are already active on this PC, and game downloads/updates remain 100% online!", "Already Protected", 'OK', 'Information') | Out-Null
        return
    }
    $preview = ($plan.Summary | ForEach-Object { "• $_" }) -join "`n"
    $ans = [System.Windows.MessageBox]::Show(
        "Detected the following Anti-7.0 protections to apply on this PC:`n`n$preview`n`nApply these changes now?",
        "Confirm Lock Out 7.0 Updates", 'YesNo', 'Question')
    if ($ans -eq 'Yes') {
        Invoke-LockUpdates -Log $WriteLog | Out-Null
        & $RefreshUI
    }
})

$BtnToggleStrict.Add_Click({
    if ($script:LastDiag -and $script:LastDiag.StoreFwBlocked) {
        Invoke-AllowStore -Log $WriteLog | Out-Null
        & $RefreshUI
    } else {
        $ans = [System.Windows.MessageBox]::Show(
            "Optional Strict Mode blocks AppMarket.exe from accessing the internet via Windows Firewall.`n`nNOTE: This is NOT required to block GameLoop 7.0 (the NTFS + Updater shield already blocks 7.0 while keeping game downloads working!). If you enable Strict Mode, you will need to click 'Re-Allow Store Game Downloads' before downloading new games or major APK updates.`n`nEnable Optional Strict Mode anyway?",
            "Optional Strict Store Firewall Block", 'YesNo', 'Warning')
        if ($ans -eq 'Yes') {
            Invoke-StrictBlockStore -Log $WriteLog | Out-Null
            & $RefreshUI
        }
    }
})

$BtnUnblockAll.Add_Click({
    $plan = Get-UnblockAllPlan
    if (-not $plan.HasWork) {
        & $WriteLog "[OK] No active GameLoop Doctor blocks found — nothing to undo."
        [System.Windows.MessageBox]::Show("No active GameLoop Doctor blocks were detected on this PC.", "Nothing To Undo", 'OK', 'Information') | Out-Null
        return
    }
    $preview = ($plan.Summary | ForEach-Object { "• $_" }) -join "`n"
    $ans = [System.Windows.MessageBox]::Show(
        "Detected the following GameLoop Doctor blocks to reverse:`n`n$preview`n`nRestore defaults now?",
        "Confirm Undo All Blocks", 'YesNo', 'Question')
    if ($ans -eq 'Yes') {
        Invoke-UnblockAll -Log $WriteLog | Out-Null
        & $RefreshUI
    }
})

$BtnOptimize.Add_Click({
    $plan = Get-OptimizeWindowsPlan
    if (-not $plan.HasWork) {
        $msg = if ($plan.DetectedExes.Count -eq 0) {
            "No installed GameLoop executables were detected yet, and Xbox Game DVR is already OFF. Install GameLoop first, then re-run this check!"
        } else {
            "All detected Windows performance optimizations are already applied on this PC!"
        }
        & $WriteLog "[OK] $msg"
        [System.Windows.MessageBox]::Show($msg, "Already Optimal", 'OK', 'Information') | Out-Null
        return
    }
    $preview = ($plan.Summary | ForEach-Object { "• $_" }) -join "`n"
    $ans = [System.Windows.MessageBox]::Show(
        "Based on this PC's hardware & installed GameLoop files, the following optimizations will be applied:`n`n$preview`n`nApply these optimizations now?",
        "Confirm Performance Optimizations", 'YesNo', 'Question')
    if ($ans -eq 'Yes') {
        Invoke-OptimizeWindows -Log $WriteLog | Out-Null
        & $RefreshUI
    }
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
    & $WriteLog "GameLoop Doctor v$($script:AppVersion) ready. Running read-only system scan..."
    & $RefreshUI
    & $WriteLog "Initial scan complete. No changes are applied until you confirm."
})

$window.ShowDialog() | Out-Null
