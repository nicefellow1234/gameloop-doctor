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
$script:AppVersion   = '1.1.0'
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

    # Read 64-bit VRAM accurately from display adapter class registry (WMI AdapterRAM overflows at 4 GB)
    $vramByName = @{}
    foreach ($adapterKey in (Get-ItemProperty 'HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0*' -Name 'DriverDesc', 'HardwareInformation.qwMemorySize' -ErrorAction SilentlyContinue)) {
        if ($adapterKey.DriverDesc -and $adapterKey.'HardwareInformation.qwMemorySize') {
            $gb = [math]::Round(([double]$adapterKey.'HardwareInformation.qwMemorySize' / 1GB), 1)
            if (-not $vramByName.ContainsKey($adapterKey.DriverDesc) -or $gb -gt $vramByName[$adapterKey.DriverDesc]) {
                $vramByName[$adapterKey.DriverDesc] = $gb
            }
        }
    }

    $controllers = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -and ($_.Name -notmatch $virtualPattern)
    })

    $allRaw     = @($controllers | Select-Object -ExpandProperty Name -Unique)
    $discrete   = @($allRaw | Where-Object { $_ -match $discretePattern })
    $integrated = @($allRaw | Where-Object { ($_ -notmatch $discretePattern) -and ($_ -match $integratedPattern) })

    $primaryGpuName = if ($discrete.Count -gt 0) { $discrete[0] } elseif ($allRaw.Count -gt 0) { $allRaw[0] } else { 'Unknown GPU' }
    $primaryVramGb  = 0.0
    if ($vramByName.ContainsKey($primaryGpuName)) {
        $primaryVramGb = $vramByName[$primaryGpuName]
    } else {
        $matchCtrl = $controllers | Where-Object { $_.Name -eq $primaryGpuName } | Select-Object -First 1
        if ($matchCtrl -and $matchCtrl.AdapterRAM -gt 0) {
            $primaryVramGb = [math]::Round(([double]$matchCtrl.AdapterRAM / 1GB), 1)
        }
    }

    $activeDisplay = $controllers | Where-Object { $_.CurrentHorizontalResolution -gt 0 -and $_.CurrentVerticalResolution -gt 0 } | Select-Object -First 1
    $monW   = if ($activeDisplay) { [int]$activeDisplay.CurrentHorizontalResolution } else { 1920 }
    $monH   = if ($activeDisplay) { [int]$activeDisplay.CurrentVerticalResolution } else { 1080 }
    $monHz  = if ($activeDisplay -and $activeDisplay.CurrentRefreshRate -gt 0) { [int]$activeDisplay.CurrentRefreshRate } else { 60 }

    return [PSCustomObject]@{
        AllGpus         = $allRaw
        DiscreteGpus    = $discrete
        IntegratedGpus  = $integrated
        HasDiscreteGpu  = ($discrete.Count -gt 0)
        IsHybridDualGpu = ($discrete.Count -gt 0 -and $integrated.Count -gt 0)
        PrimaryGpuName  = $primaryGpuName
        PrimaryVramGb   = $primaryVramGb
        MonitorWidth    = $monW
        MonitorHeight   = $monH
        MonitorHz       = $monHz
    }
}

function Get-PcSpecsAndProfile {
    param(
        $GpuProfile = $null,
        [int]$DisplayScalingPct = 0
    )
    if (-not $GpuProfile) { $GpuProfile = Get-GpuProfile }
    if ($DisplayScalingPct -le 0) { $DisplayScalingPct = Get-DisplayScalingPercent }

    $cpuObj = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $cpuName       = if ($cpuObj -and $cpuObj.Name) { ($cpuObj.Name -replace '\s+', ' ').Trim() } else { 'Unknown CPU' }
    $logicalCores  = if ($cpuObj -and $cpuObj.NumberOfLogicalProcessors -gt 0) { [int]$cpuObj.NumberOfLogicalProcessors } else { [Environment]::ProcessorCount }
    $physicalCores = if ($cpuObj -and $cpuObj.NumberOfCores -gt 0) { [int]$cpuObj.NumberOfCores } else { [math]::Max(2, [int]($logicalCores / 2)) }

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $totalRamGb = if ($os -and $os.TotalVisibleMemorySize -gt 0) { [math]::Round($os.TotalVisibleMemorySize / 1MB, 1) } else { 8.0 }
    $ramUsedPct = if ($os -and $os.TotalVisibleMemorySize -gt 0) {
        [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 0)
    } else { 0 }

    # Classify hardware tier generically for any Windows 10/11 PC
    if ($totalRamGb -ge 24 -and $physicalCores -ge 8 -and $GpuProfile.HasDiscreteGpu -and $GpuProfile.PrimaryVramGb -ge 8) {
        $tier = 'Ultra'
    } elseif ($totalRamGb -ge 15 -and $physicalCores -ge 6 -and $GpuProfile.HasDiscreteGpu -and $GpuProfile.PrimaryVramGb -ge 5) {
        $tier = 'High-End'
    } elseif ($totalRamGb -ge 7.5 -and $logicalCores -ge 4 -and (($GpuProfile.HasDiscreteGpu -and $GpuProfile.PrimaryVramGb -ge 2) -or $totalRamGb -ge 15)) {
        $tier = 'Mid-Range'
    } else {
        $tier = 'Entry'
    }

    # Compute safe, spec-matched Classic GameLoop Engine preferences (never exceeds host RAM/CPU/Monitor!)
    $recCpu = if ($physicalCores -ge 8) { 8 } elseif ($physicalCores -ge 4) { 4 } else { 2 }
    $recRam = if ($totalRamGb -ge 15) { 8192 } elseif ($totalRamGb -ge 7.5) { 4096 } else { 2048 }

    if (($tier -in @('Ultra', 'High-End')) -and $GpuProfile.MonitorWidth -ge 2560 -and $GpuProfile.MonitorHeight -ge 1440) {
        $recW = 2560; $recH = 1440; $recDpi = 240; $recGameRes = 'Ultra HD 2K'
    } elseif (($tier -in @('Ultra', 'High-End', 'Mid-Range')) -and $GpuProfile.MonitorWidth -ge 1920 -and $GpuProfile.MonitorHeight -ge 1080) {
        $recW = 1920; $recH = 1080; $recDpi = 240; $recGameRes = 'HD 1080p'
    } else {
        $recW = 1280; $recH = 720;  $recDpi = 160; $recGameRes = 'SD 720p'
    }

    $recFps = if (($tier -in @('Ultra', 'High-End')) -and $GpuProfile.MonitorHz -ge 90) { '90 / 120 FPS' } elseif ($tier -eq 'Mid-Range') { '60 / 90 FPS' } else { 'Smooth / 60 FPS' }

    $engineSettings = [ordered]@{
        VMCpuCount              = $recCpu
        VMMemorySizeInMB        = $recRam
        VMResWidth              = $recW
        VMResHeight             = $recH
        VMDPI                   = $recDpi
        ShaderCacheEnabled      = 1
        LocalShaderCacheEnabled = 1
        RenderOptimizeEnabled   = 1
        GraphicsCardEnabled     = $(if ($GpuProfile.HasDiscreteGpu) { 1 } else { 0 })
        VSyncEnabled            = 0
        FxaaQuality             = 0
    }

    return [PSCustomObject]@{
        CpuName             = $cpuName
        PhysicalCores       = $physicalCores
        LogicalCores        = $logicalCores
        TotalRamGb          = $totalRamGb
        RamUsedPercent      = $ramUsedPct
        PrimaryGpuName      = $GpuProfile.PrimaryGpuName
        PrimaryVramGb       = $GpuProfile.PrimaryVramGb
        HasDiscreteGpu      = $GpuProfile.HasDiscreteGpu
        MonitorWidth        = $GpuProfile.MonitorWidth
        MonitorHeight       = $GpuProfile.MonitorHeight
        MonitorHz           = $GpuProfile.MonitorHz
        DisplayScalingPct   = $DisplayScalingPct
        Tier                = $tier
        RecommendedCpu      = $recCpu
        RecommendedRamMb    = $recRam
        RecommendedWidth    = $recW
        RecommendedHeight   = $recH
        RecommendedDpi      = $recDpi
        RecommendedGameRes  = $recGameRes
        RecommendedFps      = $recFps
        EngineSettings      = $engineSettings
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
    $pcSpecs    = Get-PcSpecsAndProfile -GpuProfile $gpuProfile -DisplayScalingPct $dpiPct
    $defender   = Get-DefenderState

    $totalRamGb = $pcSpecs.TotalRamGb
    $ramPct     = $pcSpecs.RamUsedPercent

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
        PcSpecs           = $pcSpecs
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
    $pcSpecs    = Get-PcSpecsAndProfile -GpuProfile $gpuProfile -DisplayScalingPct $dpiPct
    $defender   = Get-DefenderState
    $exes       = Get-AllGameLoopExecutables
    $classic    = Find-ClassicGameLoop
    $gl7Dirs    = Find-GameLoop7Installs

    $gpuReg     = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $dpiReg     = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
    $classicReg = 'HKCU:\Software\Tencent\MobileGamePC'

    # 1. Spec-matched Classic GameLoop Engine Registry settings (only keys that differ from recommended profile)
    $engineChanges = New-Object System.Collections.Generic.List[PSCustomObject]
    if ($classic -and (Test-Path -LiteralPath $classicReg)) {
        $curProps = Get-ItemProperty -LiteralPath $classicReg -ErrorAction SilentlyContinue
        foreach ($kv in $pcSpecs.EngineSettings.GetEnumerator()) {
            $curVal = $curProps.($kv.Key)
            if ($null -eq $curVal -or ([int]$curVal -ne [int]$kv.Value)) {
                $engineChanges.Add([PSCustomObject]@{
                    Name     = $kv.Key
                    Current  = $(if ($null -eq $curVal) { 'Unset' } else { "$curVal" })
                    NewValue = [int]$kv.Value
                })
            }
        }
    }

    # 2. Windows GPU & AppCompat High-DPI / FSO fixes
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

    # 3. Xbox Game DVR
    $gameDvrVal     = (Get-ItemProperty -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -ErrorAction SilentlyContinue).GameDVR_Enabled
    $appCaptureVal  = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -ErrorAction SilentlyContinue).AppCaptureEnabled
    $needDisableDvr = ($gameDvrVal -ne 0) -or ($appCaptureVal -ne 0)

    # 4. Windows Defender exclusions (only if Defender service is active)
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

    $classicRunning = @(Get-Process -Name 'AndroidEmulatorEn', 'AndroidEmulatorEx', 'AndroidEmulator', 'aow_exe', 'AppMarket' -ErrorAction SilentlyContinue).Count -gt 0

    $summary = New-Object System.Collections.Generic.List[string]
    if ($exes.Count -eq 0) {
        $summary.Add("[Notice] No installed GameLoop executables detected yet (engine/GPU/DPI tuning skipped until installed)")
    }
    if ($engineChanges.Count -gt 0) {
        $detail = ($engineChanges | ForEach-Object { "$($_.Name): $($_.Current) -> $($_.NewValue)" }) -join ', '
        $summary.Add("Tune Classic GameLoop Engine for $($pcSpecs.Tier) PC ($($pcSpecs.RecommendedCpu) vCPU, $($pcSpecs.RecommendedRamMb) MB RAM, $($pcSpecs.RecommendedWidth)x$($pcSpecs.RecommendedHeight), $($pcSpecs.RecommendedDpi) DPI): $detail")
        if ($classicRunning) {
            $summary.Add("[Tip] Classic GameLoop is currently open — restart GameLoop afterward so engine changes take effect")
        }
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

    $hasWork = ($engineChanges.Count -gt 0) -or ($gpuToPin.Count -gt 0) -or ($dpiToFix.Count -gt 0) -or
               $needDisableDvr -or ($missingDefPaths.Count -gt 0) -or ($missingDefProcs.Count -gt 0)

    return [PSCustomObject]@{
        GpuProfile      = $gpuProfile
        PcSpecs         = $pcSpecs
        DisplayScaling  = $dpiPct
        Defender        = $defender
        DetectedExes    = $exes
        EngineChanges   = $engineChanges.ToArray()
        ClassicRunning  = $classicRunning
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

    & $Log "=== Applying Spec-Matched Optional Optimizations ($($plan.PcSpecs.Tier) PC Profile) ==="

    $classicReg = 'HKCU:\Software\Tencent\MobileGamePC'
    if ($plan.EngineChanges.Count -gt 0 -and (Test-Path -LiteralPath $classicReg)) {
        foreach ($chg in $plan.EngineChanges) {
            Set-ItemProperty -Path $classicReg -Name $chg.Name -Value ([int]$chg.NewValue) -Type DWord
            & $Log "  [Engine] Set $($chg.Name) = $($chg.NewValue) (was $($chg.Current))"
        }
        if ($plan.ClassicRunning) {
            & $Log "  [TIP] Restart Classic GameLoop so the updated Engine settings take effect."
        }
    }

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
        Write-Host ("  Detected PC Tier    : {0} ({1} | {2}C/{3}T | {4} GB RAM)" -f $d.PcSpecs.Tier, $d.PcSpecs.CpuName, $d.PcSpecs.PhysicalCores, $d.PcSpecs.LogicalCores, $d.PcSpecs.TotalRamGb)
        Write-Host ("  Primary GPU / VRAM  : {0} ({1} GB VRAM, Discrete={2})" -f $d.PcSpecs.PrimaryGpuName, $d.PcSpecs.PrimaryVramGb, $d.PcSpecs.HasDiscreteGpu)
        Write-Host ("  Display & Scaling   : {0}x{1} @ {2} Hz ({3}% DPI)" -f $d.PcSpecs.MonitorWidth, $d.PcSpecs.MonitorHeight, $d.PcSpecs.MonitorHz, $d.DisplayScalingPct)
        Write-Host ("  Optional Spec Profile: {0} vCPU | {1} MB RAM | {2}x{3} | {4} DPI | Game Res: {5}" -f $d.PcSpecs.RecommendedCpu, $d.PcSpecs.RecommendedRamMb, $d.PcSpecs.RecommendedWidth, $d.PcSpecs.RecommendedHeight, $d.PcSpecs.RecommendedDpi, $d.PcSpecs.RecommendedGameRes)
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
# 6. NATIVE WINDOWS WPF DESKTOP APP (Easy Mode Default + Advanced Mode)
# ============================================================================
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Enable native Windows 10/11 Dark Title Bar (no stark white caption bar!)
if (-not ([System.Management.Automation.PSTypeName]'GameLoopDoctorDwm').Type) {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class GameLoopDoctorDwm {
    [DllImport("dwmapi.dll", PreserveSig = true)]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
}
"@ -ErrorAction SilentlyContinue
    } catch { }
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="GameLoop Doctor v1.1"
        Height="790" Width="1060" MinHeight="650" MinWidth="900"
        WindowStartupLocation="CenterScreen"
        Background="#0B0F19" Foreground="#F1F5F9" FontFamily="Segoe UI"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display">
    <Window.Resources>
        <DropShadowEffect x:Key="SoftShadow" BlurRadius="22" ShadowDepth="4" Direction="270" Color="#000000" Opacity="0.35"/>

        <!-- Sleek Minimal Dark ScrollBar -->
        <Style TargetType="ScrollBar">
            <Setter Property="Width" Value="8"/>
            <Setter Property="MinWidth" Value="8"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Grid Background="Transparent" Margin="1,2">
                            <Track x:Name="PART_Track" IsDirectionReversed="True">
                                <Track.Thumb>
                                    <Thumb>
                                        <Thumb.Template>
                                            <ControlTemplate TargetType="Thumb">
                                                <Border x:Name="thumbBd" Background="#273654" CornerRadius="4" Margin="1,0"/>
                                                <ControlTemplate.Triggers>
                                                    <Trigger Property="IsMouseOver" Value="True">
                                                        <Setter TargetName="thumbBd" Property="Background" Value="#3E5580"/>
                                                    </Trigger>
                                                </ControlTemplate.Triggers>
                                            </ControlTemplate>
                                        </Thumb.Template>
                                    </Thumb>
                                </Track.Thumb>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background" Value="#131926"/>
            <Setter Property="BorderBrush" Value="#1F2B42"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="12"/>
            <Setter Property="Padding" Value="18"/>
            <Setter Property="Effect" Value="{StaticResource SoftShadow}"/>
        </Style>

        <Style x:Key="HeroCard" TargetType="Border">
            <Setter Property="BorderBrush" Value="#273B63"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="14"/>
            <Setter Property="Padding" Value="22,20"/>
            <Setter Property="Effect" Value="{StaticResource SoftShadow}"/>
            <Setter Property="Background">
                <Setter.Value>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#16213A" Offset="0"/>
                        <GradientStop Color="#111829" Offset="0.65"/>
                        <GradientStop Color="#131A2C" Offset="1"/>
                    </LinearGradientBrush>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="PrimaryBtn" TargetType="Button">
            <Setter Property="Background" Value="#2563EB"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="16,10"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Opacity" Value="0.88"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bd" Property="Opacity" Value="0.76"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bd" Property="Opacity" Value="0.45"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SubtleBtn" TargetType="Button" BasedOn="{StaticResource PrimaryBtn}">
            <Setter Property="Background" Value="#1B2437"/>
            <Setter Property="Foreground" Value="#CBD5E1"/>
            <Setter Property="BorderBrush" Value="#2C3B59"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Padding" Value="13,7"/>
        </Style>

        <Style x:Key="ModePillBtn" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#94A3B8"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Padding" Value="16,7"/>
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
                                <Setter TargetName="bd" Property="Opacity" Value="0.9"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="LinkBtn" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#60A5FA"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Padding" Value="4,2"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Background="#0B0F19">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- ==================== TOP NAVIGATION BAR ==================== -->
        <Border Grid.Row="0" Background="#0F1524" BorderBrush="#1C273D" BorderThickness="0,0,0,1" Padding="22,14">
            <Grid MaxWidth="1180">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <!-- Brand -->
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                    <Border Width="38" Height="38" CornerRadius="10" Margin="0,0,12,0">
                        <Border.Background>
                            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                <GradientStop Color="#2563EB" Offset="0"/>
                                <GradientStop Color="#7C3AED" Offset="1"/>
                            </LinearGradientBrush>
                        </Border.Background>
                        <Path Data="M12,2 L4,5.5 V11.5 C4,16.8 7.4,21.5 12,23 C16.6,21.5 20,16.8 20,11.5 V5.5 L12,2 Z M10.5,16.2 L7.2,12.9 L8.6,11.5 L10.5,13.4 L15.4,8.5 L16.8,9.9 L10.5,16.2 Z"
                              Fill="White" Stretch="Uniform" Width="20" Height="20" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <StackPanel VerticalAlignment="Center">
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <TextBlock Text="GameLoop Doctor" FontSize="19" FontWeight="Bold" Foreground="#F8FAFC"/>
                            <Border Background="#1B2742" CornerRadius="5" Padding="6,2" Margin="8,0,0,0" VerticalAlignment="Center">
                                <TextBlock x:Name="TxtVersionBadge" Text="v1.1" FontSize="10.5" FontWeight="SemiBold" Foreground="#93C5FD"/>
                            </Border>
                        </StackPanel>
                        <TextBlock Text="Anti-Cheat Safe • Detects Your PC First" FontSize="11.5" Foreground="#7D90B2" Margin="0,1,0,0"/>
                    </StackPanel>
                </StackPanel>

                <!-- Segmented Mode Switcher (Easy Mode Default / Advanced Mode) -->
                <Border Grid.Column="1" Background="#161E31" BorderBrush="#263452" BorderThickness="1" CornerRadius="10" Padding="4" VerticalAlignment="Center">
                    <StackPanel Orientation="Horizontal">
                        <Button x:Name="BtnModeEasy" Content="Easy Mode" Style="{StaticResource ModePillBtn}" Background="#2563EB" Foreground="#FFFFFF"/>
                        <Button x:Name="BtnModeAdvanced" Content="Advanced Mode" Style="{StaticResource ModePillBtn}" Margin="4,0,0,0"/>
                    </StackPanel>
                </Border>

                <!-- Right Controls (Properly right-aligned!) -->
                <StackPanel Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                    <Border x:Name="AdminBadge" Background="#103629" BorderBrush="#1C5B42" BorderThickness="1" CornerRadius="7" Padding="10,5" Margin="0,0,10,0" VerticalAlignment="Center">
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <Ellipse x:Name="AdminDot" Width="7" Height="7" Fill="#34D399" Margin="0,0,6,0" VerticalAlignment="Center"/>
                            <TextBlock x:Name="AdminBadgeText" Text="Admin" FontSize="11.5" FontWeight="SemiBold" Foreground="#86EFAC"/>
                        </StackPanel>
                    </Border>
                    <Button x:Name="BtnRefresh" Content="Rescan PC" Style="{StaticResource SubtleBtn}" VerticalAlignment="Center"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- ==================== MAIN CONTENT AREA ==================== -->
        <Grid Grid.Row="1">

            <!-- ==================== EASY MODE (DEFAULT) ==================== -->
            <ScrollViewer x:Name="EasyPanel" Visibility="Visible" VerticalScrollBarVisibility="Auto" Padding="22,14">
                <StackPanel MaxWidth="1120" HorizontalAlignment="Stretch">

                    <!-- PRIMARY HERO: BLOCK GAMELOOP 7.0 BETA AUTO-UPDATES -->
                    <Border Style="{StaticResource HeroCard}" Padding="20,16" Margin="0,0,0,12">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>

                            <!-- Health Circle -->
                            <Border x:Name="EasyHeroCircle" Grid.Column="0" Width="58" Height="58" CornerRadius="29"
                                    Background="#1F2937" BorderBrush="#334155" BorderThickness="1.5" Margin="0,0,18,0" VerticalAlignment="Center">
                                <Path x:Name="EasyHeroIcon"
                                      Data="M12,2 L4,5.5 V11.5 C4,16.8 7.4,21.5 12,23 C16.6,21.5 20,16.8 20,11.5 V5.5 L12,2 Z"
                                      Fill="#60A5FA" Stretch="Uniform" Width="26" Height="26" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>

                            <!-- Friendly Primary Headline -->
                            <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,18,0">
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,3">
                                    <Border Background="#123026" BorderBrush="#1F5943" BorderThickness="1" CornerRadius="5" Padding="7,2">
                                        <TextBlock Text="PRIMARY PROTECTION" FontSize="10" FontWeight="Bold" Foreground="#6EE7B7"/>
                                    </Border>
                                </StackPanel>
                                <TextBlock x:Name="EasyHeroTitle" Text="Scanning your GameLoop setup..." FontSize="19.5" FontWeight="Bold" Foreground="#F8FAFC" TextWrapping="Wrap"/>
                                <TextBlock x:Name="EasyHeroSub" Text="Checking your installed version &amp; 7.0 beta auto-update protection — nothing is changed yet."
                                           FontSize="12.5" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,3,0,0"/>
                            </StackPanel>

                            <!-- Primary 1-Click Action (Update Blocker / Remove 7.0 ONLY!) -->
                            <Button x:Name="BtnEasyFixAll" Grid.Column="2" Content="Block 7.0 Beta Updates" Style="{StaticResource PrimaryBtn}"
                                    Background="#059669" Padding="22,13" FontSize="14" VerticalAlignment="Center"/>
                        </Grid>
                    </Border>

                    <!-- 2 PRIMARY CORE CARDS: EDITION & AUTO-UPDATE BLOCKER -->
                    <Grid Margin="0,0,0,12">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="14"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>

                        <!-- CORE CARD 1: GAMELOOP EDITION -->
                        <Border Grid.Column="0" Style="{StaticResource Card}" Padding="16,14" MinHeight="168">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="*"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>

                                <Grid Grid.Row="0" Margin="0,0,0,10">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="Auto"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <Border Width="34" Height="34" CornerRadius="9" Background="#172542" Margin="0,0,10,0">
                                        <Path Data="M6,9 H18 A4,4 0 0 1 22,13 V16 A3,3 0 0 1 19,19 H17 L15,16 H9 L7,19 H5 A3,3 0 0 1 2,16 V13 A4,4 0 0 1 6,9 Z"
                                              Stroke="#60A5FA" StrokeThickness="1.7" Stretch="Uniform" Width="18" Height="18" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <TextBlock Grid.Column="1" Text="1. GameLoop Edition" FontSize="15" FontWeight="Bold" Foreground="#F1F5F9" VerticalAlignment="Center"/>
                                    <Border x:Name="EasyBadge1" Grid.Column="2" Background="#1E293B" CornerRadius="6" Padding="8,3" VerticalAlignment="Center">
                                        <TextBlock x:Name="EasyBadge1Text" Text="Scanning" FontSize="11" FontWeight="SemiBold" Foreground="#94A3B8"/>
                                    </Border>
                                </Grid>

                                <StackPanel Grid.Row="1" Margin="0,0,0,14">
                                    <TextBlock x:Name="EasyDesc1" Text="Checking whether Classic GameLoop or GameLoop 7.0 beta is installed..."
                                               FontSize="12.5" Foreground="#CBD5E1" TextWrapping="Wrap" LineHeight="19"/>
                                    <TextBlock x:Name="EasySub1" Text="" FontSize="11.5" Foreground="#64748B" TextWrapping="Wrap" Margin="0,6,0,0"/>
                                </StackPanel>

                                <Button x:Name="BtnEasyCard1" Grid.Row="2" Content="Launch Classic GameLoop" Style="{StaticResource PrimaryBtn}" HorizontalAlignment="Stretch"/>
                            </Grid>
                        </Border>

                        <!-- CORE CARD 2: BLOCK 7.0 BETA AUTO-UPDATES -->
                        <Border Grid.Column="2" Style="{StaticResource Card}" Padding="16,14" MinHeight="168">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="*"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>

                                <Grid Grid.Row="0" Margin="0,0,0,10">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="Auto"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <Border Width="34" Height="34" CornerRadius="9" Background="#0F2D25" Margin="0,0,10,0">
                                        <Path Data="M12,2 L4,5.5 V11.5 C4,16.8 7.4,21.5 12,23 C16.6,21.5 20,16.8 20,11.5 V5.5 L12,2 Z"
                                              Stroke="#34D399" StrokeThickness="1.8" Stretch="Uniform" Width="17" Height="17" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <TextBlock Grid.Column="1" Text="2. Block 7.0 Beta Auto-Updates" FontSize="15" FontWeight="Bold" Foreground="#F1F5F9" VerticalAlignment="Center"/>
                                    <Border x:Name="EasyBadge2" Grid.Column="2" Background="#1E293B" CornerRadius="6" Padding="8,3" VerticalAlignment="Center">
                                        <TextBlock x:Name="EasyBadge2Text" Text="Scanning" FontSize="11" FontWeight="SemiBold" Foreground="#94A3B8"/>
                                    </Border>
                                </Grid>

                                <StackPanel Grid.Row="1" Margin="0,0,0,14">
                                    <TextBlock x:Name="EasyDesc2" Text="Permanently stops Classic GameLoop from upgrading to the new 7.0 beta — while PUBG Mobile &amp; all game updates keep working 100% online."
                                               FontSize="12.5" Foreground="#CBD5E1" TextWrapping="Wrap" LineHeight="19"/>
                                    <TextBlock x:Name="EasySub2" Text="" FontSize="11.5" Foreground="#64748B" TextWrapping="Wrap" Margin="0,6,0,0"/>
                                </StackPanel>

                                <Button x:Name="BtnEasyCard2" Grid.Row="2" Content="Block 7.0 Beta Auto-Updates" Style="{StaticResource PrimaryBtn}" Background="#059669" HorizontalAlignment="Stretch"/>
                            </Grid>
                        </Border>
                    </Grid>

                    <!-- OPTIONAL EXTRA: AUTO-DETECTED PC SPECS & SPEC-MATCHED OPTIMIZER -->
                    <Border Style="{StaticResource Card}" Padding="18,16" Margin="0,0,0,14" BorderBrush="#28234A">
                        <StackPanel>
                            <!-- Section Header -->
                            <Grid Margin="0,0,0,12">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                                    <Border Width="32" Height="32" CornerRadius="8" Background="#261942" Margin="0,0,10,0">
                                        <Path Data="M13,2 L4,14 H11 L10,22 L20,10 H13 L13,2 Z"
                                              Stroke="#A78BFA" StrokeThickness="1.8" Stretch="Uniform" Width="16" Height="16" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <TextBlock Text="PC Spec Auto-Optimizer" FontSize="15" FontWeight="Bold" Foreground="#F1F5F9" VerticalAlignment="Center"/>
                                    <Border Background="#2B1B4A" BorderBrush="#4C2E85" BorderThickness="1" CornerRadius="5" Padding="7,2" Margin="10,0,0,0" VerticalAlignment="Center">
                                        <TextBlock Text="OPTIONAL EXTRA" FontSize="10" FontWeight="Bold" Foreground="#C4B5FD"/>
                                    </Border>
                                </StackPanel>
                                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                                    <Border x:Name="EasyTierBadge" Background="#172542" BorderBrush="#2C4478" BorderThickness="1" CornerRadius="6" Padding="9,3" Margin="0,0,8,0">
                                        <TextBlock x:Name="EasyTierBadgeText" Text="Detecting Specs..." FontSize="11" FontWeight="SemiBold" Foreground="#93C5FD"/>
                                    </Border>
                                    <Border x:Name="EasyBadge3" Background="#1E293B" CornerRadius="6" Padding="8,3">
                                        <TextBlock x:Name="EasyBadge3Text" Text="Optional" FontSize="11" FontWeight="SemiBold" Foreground="#94A3B8"/>
                                    </Border>
                                </StackPanel>
                            </Grid>

                            <!-- 4 Detected PC Spec Mini-Pills -->
                            <Grid Margin="0,0,0,12">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="10"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="10"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="10"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <Border Grid.Column="0" Background="#0E1422" BorderBrush="#1D2840" BorderThickness="1" CornerRadius="8" Padding="10,8">
                                    <StackPanel>
                                        <TextBlock Text="CPU" FontSize="10" FontWeight="Bold" Foreground="#60A5FA"/>
                                        <TextBlock x:Name="EasySpecCpu" Text="Detecting..." FontSize="12" FontWeight="SemiBold" Foreground="#E2E8F0" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                                        <TextBlock x:Name="EasySpecCpuSub" Text="" FontSize="10.5" Foreground="#64748B"/>
                                    </StackPanel>
                                </Border>

                                <Border Grid.Column="2" Background="#0E1422" BorderBrush="#1D2840" BorderThickness="1" CornerRadius="8" Padding="10,8">
                                    <StackPanel>
                                        <TextBlock Text="GPU &amp; VRAM" FontSize="10" FontWeight="Bold" Foreground="#A78BFA"/>
                                        <TextBlock x:Name="EasySpecGpu" Text="Detecting..." FontSize="12" FontWeight="SemiBold" Foreground="#E2E8F0" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                                        <TextBlock x:Name="EasySpecGpuSub" Text="" FontSize="10.5" Foreground="#64748B"/>
                                    </StackPanel>
                                </Border>

                                <Border Grid.Column="4" Background="#0E1422" BorderBrush="#1D2840" BorderThickness="1" CornerRadius="8" Padding="10,8">
                                    <StackPanel>
                                        <TextBlock Text="MEMORY (RAM)" FontSize="10" FontWeight="Bold" Foreground="#34D399"/>
                                        <TextBlock x:Name="EasySpecRam" Text="Detecting..." FontSize="12" FontWeight="SemiBold" Foreground="#E2E8F0" Margin="0,2,0,0"/>
                                        <TextBlock x:Name="EasySpecRamSub" Text="" FontSize="10.5" Foreground="#64748B"/>
                                    </StackPanel>
                                </Border>

                                <Border Grid.Column="6" Background="#0E1422" BorderBrush="#1D2840" BorderThickness="1" CornerRadius="8" Padding="10,8">
                                    <StackPanel>
                                        <TextBlock Text="MONITOR &amp; DPI" FontSize="10" FontWeight="Bold" Foreground="#FBBF24"/>
                                        <TextBlock x:Name="EasySpecMon" Text="Detecting..." FontSize="12" FontWeight="SemiBold" Foreground="#E2E8F0" Margin="0,2,0,0"/>
                                        <TextBlock x:Name="EasySpecMonSub" Text="" FontSize="10.5" Foreground="#64748B"/>
                                    </StackPanel>
                                </Border>
                            </Grid>

                            <!-- Recommended Spec Profile + Optional Apply Button -->
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0" VerticalAlignment="Center" Margin="0,0,16,0">
                                    <TextBlock x:Name="EasyDesc3" Text="Calculating tailored settings for your PC specs..."
                                               FontSize="12.5" Foreground="#CBD5E1" TextWrapping="Wrap"/>
                                    <TextBlock x:Name="EasySub3" Text="" FontSize="11.5" Foreground="#7D90B2" TextWrapping="Wrap" Margin="0,3,0,0"/>
                                </StackPanel>
                                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                                    <Button x:Name="BtnEasyOpenHvci" Content="Core Isolation" Style="{StaticResource SubtleBtn}" Margin="0,0,8,0" Visibility="Collapsed"/>
                                    <Button x:Name="BtnEasyCard3" Content="Apply Optional Optimization" Style="{StaticResource PrimaryBtn}" Background="#7C3AED"/>
                                </StackPanel>
                            </Grid>

                            <!-- Optional Manual Tips Sub-row (collapsed if none) -->
                            <Border x:Name="EasyTipsBox" Background="#0E1422" BorderBrush="#1C273D" BorderThickness="1" CornerRadius="8" Padding="12,9" Margin="0,12,0,0">
                                <StackPanel>
                                    <TextBlock x:Name="EasyTipsTitle" Text="Optional Gameplay Tips" FontSize="11.5" FontWeight="Bold" Foreground="#94A3B8" Margin="0,0,0,3"/>
                                    <TextBlock x:Name="EasyTipsBody" Text="Scanning background apps &amp; Windows settings..." FontSize="11.5" Foreground="#7D90B2" TextWrapping="Wrap" LineHeight="18"/>
                                </StackPanel>
                            </Border>
                        </StackPanel>
                    </Border>

                    <!-- CLEAN FOOTER STATUS STRIP -->
                    <Border Background="#0F1524" BorderBrush="#1C273D" BorderThickness="1" CornerRadius="10" Padding="14,10">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <Ellipse Grid.Column="0" Width="8" Height="8" Fill="#34D399" Margin="0,0,10,0" VerticalAlignment="Center"/>
                            <TextBlock x:Name="EasyStatusLine" Grid.Column="1" Text="Ready — Scanned your PC safely. No changes are made until you confirm."
                                       FontSize="12" Foreground="#94A3B8" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                            <Button x:Name="BtnEasyToAdvanced" Grid.Column="2" Content="Advanced Controls &amp; Log  -&gt;" Style="{StaticResource LinkBtn}" Margin="12,0,0,0" VerticalAlignment="Center"/>
                        </Grid>
                    </Border>
                </StackPanel>
            </ScrollViewer>

            <!-- ==================== ADVANCED MODE ==================== -->
            <Grid x:Name="AdvancedPanel" Visibility="Collapsed" Margin="20,16" MaxWidth="1180">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="175"/>
                </Grid.RowDefinitions>

                <!-- ROW 0: DETAILED TELEMETRY CARDS -->
                <Grid Grid.Row="0" Margin="0,0,0,12">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="12"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="12"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <Border Grid.Column="0" Style="{StaticResource Card}" Padding="15,13">
                        <StackPanel>
                            <TextBlock Text="GAMELOOP EDITION" FontSize="10.5" FontWeight="Bold" Foreground="#60A5FA"/>
                            <TextBlock x:Name="TxtEdition" Text="Scanning..." FontSize="14.5" FontWeight="SemiBold" Margin="0,5,0,3" TextWrapping="Wrap"/>
                            <TextBlock x:Name="TxtEditionSub" Text="" FontSize="11.5" Foreground="#94A3B8" TextWrapping="Wrap" LineHeight="16"/>
                        </StackPanel>
                    </Border>

                    <Border Grid.Column="2" Style="{StaticResource Card}" Padding="15,13">
                        <StackPanel>
                            <TextBlock Text="ANTI-7.0 EMULATOR SHIELD" FontSize="10.5" FontWeight="Bold" Foreground="#34D399"/>
                            <TextBlock x:Name="TxtShield" Text="Scanning..." FontSize="14.5" FontWeight="SemiBold" Margin="0,5,0,3" TextWrapping="Wrap"/>
                            <TextBlock x:Name="TxtShieldSub" Text="" FontSize="11.5" Foreground="#94A3B8" TextWrapping="Wrap" LineHeight="16"/>
                        </StackPanel>
                    </Border>

                    <Border Grid.Column="4" Style="{StaticResource Card}" Padding="15,13">
                        <StackPanel>
                            <TextBlock Text="HARDWARE &amp; LAG TELEMETRY" FontSize="10.5" FontWeight="Bold" Foreground="#FBBF24"/>
                            <TextBlock x:Name="TxtPerf" Text="Scanning..." FontSize="14.5" FontWeight="SemiBold" Margin="0,5,0,3" TextWrapping="Wrap"/>
                            <TextBlock x:Name="TxtPerfSub" Text="" FontSize="11.5" Foreground="#94A3B8" TextWrapping="Wrap" LineHeight="16"/>
                        </StackPanel>
                    </Border>
                </Grid>

                <!-- ROW 1: GRANULAR CONTROLS -->
                <Grid Grid.Row="1" Margin="0,0,0,12">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="14"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <!-- LEFT: RESTORE CLASSIC & SURGICAL SHIELD -->
                    <Border Grid.Column="0" Style="{StaticResource Card}" Padding="16">
                        <ScrollViewer VerticalScrollBarVisibility="Auto">
                            <StackPanel>
                                <TextBlock Text="1. Classic Restore &amp; Anti-7.0 Shield" FontSize="15" FontWeight="Bold" Foreground="#F8FAFC" Margin="0,0,0,8"/>

                                <TextBlock Text="Detect &amp; remove GameLoop 7.0 ('Androws'), GameLoopService, locked folders, and cached silent-upgraders:"
                                           FontSize="12" Foreground="#CBD5E1" TextWrapping="Wrap" Margin="0,0,0,8"/>
                                <WrapPanel Margin="0,0,0,4">
                                    <Button x:Name="BtnRemove7" Content="Remove GameLoop 7.0" Style="{StaticResource PrimaryBtn}" Background="#DC2626" Margin="0,0,8,8"/>
                                    <Button x:Name="BtnLaunchClassic" Content="Launch Classic Installer" Style="{StaticResource PrimaryBtn}" Background="#0284C7" Margin="0,0,8,8"/>
                                </WrapPanel>

                                <Border Height="1" Background="#1F2B42" Margin="0,4,0,10"/>

                                <TextBlock Text="Surgical emulator-only shield (keeps PUBG Mobile &amp; all game downloads/updates 100% online):"
                                           FontSize="12" Foreground="#CBD5E1" TextWrapping="Wrap" Margin="0,0,0,8"/>
                                <WrapPanel Margin="0,0,0,4">
                                    <Button x:Name="BtnLockUpdates" Content="Lock 7.0 Updates (Games Online)" Style="{StaticResource PrimaryBtn}" Background="#059669" Margin="0,0,8,8"/>
                                    <Button x:Name="BtnToggleStrict" Content="Strict Block Store" Style="{StaticResource PrimaryBtn}" Background="#D97706" Margin="0,0,8,8"/>
                                </WrapPanel>

                                <TextBlock Text="Locks all detected NTFS 7.0 targets, disables bundled updaters (AndrowsInstaller, pcyyb_installer, PcyybAssistant, tupdate), and converts cached silent upgraders into 0-byte locked stubs."
                                           FontSize="11" Foreground="#7D90B2" TextWrapping="Wrap" Margin="0,0,0,10"/>

                                <Button x:Name="BtnUnblockAll" Content="Undo All Blocks (Restore Defaults)" Style="{StaticResource SubtleBtn}" HorizontalAlignment="Left"/>
                            </StackPanel>
                        </ScrollViewer>
                    </Border>

                    <!-- RIGHT: PERFORMANCE, DRY RUN & DIAGNOSTICS -->
                    <Border Grid.Column="2" Style="{StaticResource Card}" Padding="16">
                        <ScrollViewer VerticalScrollBarVisibility="Auto">
                            <StackPanel>
                                <TextBlock Text="2. Optional Extra: PC Spec Auto-Optimizer &amp; Diagnostics" FontSize="15" FontWeight="Bold" Foreground="#F8FAFC" Margin="0,0,0,8"/>

                                <TextBlock Text="Optional: detects your CPU, RAM, GPU/VRAM, and monitor to tailor Classic GameLoop Engine settings (vCPU, RAM, Resolution, DPI, Cache) + Windows GPU/DPI/DVR/Defender tweaks:"
                                           FontSize="12" Foreground="#CBD5E1" TextWrapping="Wrap" Margin="0,0,0,8"/>
                                <WrapPanel Margin="0,0,0,4">
                                    <Button x:Name="BtnOptimize" Content="Apply Spec-Matched Optimization (Optional)" Style="{StaticResource PrimaryBtn}" Background="#7C3AED" Margin="0,0,8,8"/>
                                    <Button x:Name="BtnDryRunAll" Content="Preview Dry Run" Style="{StaticResource SubtleBtn}" Margin="0,0,8,8"/>
                                    <Button x:Name="BtnOpenSecurity" Content="Core Isolation (HVCI)" Style="{StaticResource SubtleBtn}" Margin="0,0,8,8"/>
                                </WrapPanel>

                                <Border Height="1" Background="#1F2B42" Margin="0,4,0,10"/>

                                <TextBlock Text="Auto-Detected System Lag Checklist:" FontSize="12.5" FontWeight="SemiBold" Foreground="#E2E8F0" Margin="0,0,0,5"/>
                                <TextBlock x:Name="TxtAdvisor" Text="Scanning hardware &amp; background apps..." FontSize="11.5" Foreground="#CBD5E1" TextWrapping="Wrap" LineHeight="19"/>
                            </StackPanel>
                        </ScrollViewer>
                    </Border>
                </Grid>

                <!-- ROW 2: LIVE ACTIVITY LOG (Fixed Grid header — no stretched buttons!) -->
                <Border Grid.Row="2" Style="{StaticResource Card}" Padding="14,12">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <Grid Grid.Row="0" Margin="0,0,0,8">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Grid.Column="0" Text="LIVE ACTIVITY LOG" FontSize="11" FontWeight="Bold" Foreground="#7D90B2" VerticalAlignment="Center"/>
                            <StackPanel Grid.Column="1" Orientation="Horizontal">
                                <Button x:Name="BtnClearLog" Content="Clear" Style="{StaticResource SubtleBtn}" Padding="10,3" FontSize="11" Margin="0,0,6,0"/>
                                <Button x:Name="BtnCopyLog" Content="Copy Log" Style="{StaticResource SubtleBtn}" Padding="10,3" FontSize="11"/>
                            </StackPanel>
                        </Grid>
                        <TextBox x:Name="TxtLog" Grid.Row="1" IsReadOnly="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                                 Background="#090D16" Foreground="#6EE7B7" BorderBrush="#1A2338" BorderThickness="1" Padding="10,8"
                                 FontFamily="Consolas" FontSize="11.5" TextWrapping="NoWrap"/>
                    </Grid>
                </Border>
            </Grid>
        </Grid>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# Apply native dark title bar when HWND is initialized
$window.Add_SourceInitialized({
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
        $useDark = 1
        [GameLoopDoctorDwm]::DwmSetWindowAttribute($hwnd, 20, [ref]$useDark, 4) | Out-Null
        [GameLoopDoctorDwm]::DwmSetWindowAttribute($hwnd, 19, [ref]$useDark, 4) | Out-Null
        # Match Windows 11 title bar color to header #0F1524 (COLORREF BGR: 0x0024150F)
        $captionBgr = 0x0024150F
        [GameLoopDoctorDwm]::DwmSetWindowAttribute($hwnd, 35, [ref]$captionBgr, 4) | Out-Null
    } catch { }
})

$Brush = {
    param([string]$Hex)
    return ([System.Windows.Media.BrushConverter]::new()).ConvertFromString($Hex)
}

# Shared header controls
$TxtVersionBadge = $window.FindName('TxtVersionBadge')
$BtnModeEasy     = $window.FindName('BtnModeEasy')
$BtnModeAdvanced = $window.FindName('BtnModeAdvanced')
$AdminBadge      = $window.FindName('AdminBadge')
$AdminDot        = $window.FindName('AdminDot')
$AdminBadgeText  = $window.FindName('AdminBadgeText')
$BtnRefresh      = $window.FindName('BtnRefresh')

# Panels
$EasyPanel     = $window.FindName('EasyPanel')
$AdvancedPanel = $window.FindName('AdvancedPanel')

# Easy Mode controls
$EasyHeroCircle    = $window.FindName('EasyHeroCircle')
$EasyHeroIcon      = $window.FindName('EasyHeroIcon')
$EasyHeroTitle     = $window.FindName('EasyHeroTitle')
$EasyHeroSub       = $window.FindName('EasyHeroSub')
$BtnEasyFixAll     = $window.FindName('BtnEasyFixAll')
$EasyBadge1        = $window.FindName('EasyBadge1')
$EasyBadge1Text    = $window.FindName('EasyBadge1Text')
$EasyDesc1         = $window.FindName('EasyDesc1')
$EasySub1          = $window.FindName('EasySub1')
$BtnEasyCard1      = $window.FindName('BtnEasyCard1')
$EasyBadge2        = $window.FindName('EasyBadge2')
$EasyBadge2Text    = $window.FindName('EasyBadge2Text')
$EasyDesc2         = $window.FindName('EasyDesc2')
$EasySub2          = $window.FindName('EasySub2')
$BtnEasyCard2      = $window.FindName('BtnEasyCard2')
$EasyBadge3        = $window.FindName('EasyBadge3')
$EasyBadge3Text    = $window.FindName('EasyBadge3Text')
$EasyTierBadge     = $window.FindName('EasyTierBadge')
$EasyTierBadgeText = $window.FindName('EasyTierBadgeText')
$EasySpecCpu       = $window.FindName('EasySpecCpu')
$EasySpecCpuSub    = $window.FindName('EasySpecCpuSub')
$EasySpecGpu       = $window.FindName('EasySpecGpu')
$EasySpecGpuSub    = $window.FindName('EasySpecGpuSub')
$EasySpecRam       = $window.FindName('EasySpecRam')
$EasySpecRamSub    = $window.FindName('EasySpecRamSub')
$EasySpecMon       = $window.FindName('EasySpecMon')
$EasySpecMonSub    = $window.FindName('EasySpecMonSub')
$EasyDesc3         = $window.FindName('EasyDesc3')
$EasySub3          = $window.FindName('EasySub3')
$BtnEasyCard3      = $window.FindName('BtnEasyCard3')
$EasyTipsTitle     = $window.FindName('EasyTipsTitle')
$EasyTipsBody      = $window.FindName('EasyTipsBody')
$BtnEasyOpenHvci   = $window.FindName('BtnEasyOpenHvci')
$EasyStatusLine    = $window.FindName('EasyStatusLine')
$BtnEasyToAdvanced = $window.FindName('BtnEasyToAdvanced')

# Advanced Mode controls
$TxtEdition       = $window.FindName('TxtEdition')
$TxtEditionSub    = $window.FindName('TxtEditionSub')
$TxtShield        = $window.FindName('TxtShield')
$TxtShieldSub     = $window.FindName('TxtShieldSub')
$TxtPerf          = $window.FindName('TxtPerf')
$TxtPerfSub       = $window.FindName('TxtPerfSub')
$TxtAdvisor       = $window.FindName('TxtAdvisor')
$TxtLog           = $window.FindName('TxtLog')
$BtnRemove7       = $window.FindName('BtnRemove7')
$BtnLaunchClassic = $window.FindName('BtnLaunchClassic')
$BtnLockUpdates   = $window.FindName('BtnLockUpdates')
$BtnToggleStrict  = $window.FindName('BtnToggleStrict')
$BtnUnblockAll    = $window.FindName('BtnUnblockAll')
$BtnOptimize      = $window.FindName('BtnOptimize')
$BtnDryRunAll     = $window.FindName('BtnDryRunAll')
$BtnOpenSecurity  = $window.FindName('BtnOpenSecurity')
$BtnClearLog      = $window.FindName('BtnClearLog')
$BtnCopyLog       = $window.FindName('BtnCopyLog')

$TxtVersionBadge.Text = "v$($script:AppVersion)"

$script:LastDiag    = $null
$script:LastLockPln = $null
$script:LastOptPln  = $null
$script:CurrentMode = 'Easy'

# Mode Switcher (Easy Mode is ON by default!)
$SetUiMode = {
    param([string]$Mode)
    $script:CurrentMode = $Mode
    if ($Mode -eq 'Easy') {
        $EasyPanel.Visibility     = 'Visible'
        $AdvancedPanel.Visibility = 'Collapsed'
        $BtnModeEasy.Background     = & $Brush '#2563EB'
        $BtnModeEasy.Foreground     = & $Brush '#FFFFFF'
        $BtnModeAdvanced.Background = [Windows.Media.Brushes]::Transparent
        $BtnModeAdvanced.Foreground = & $Brush '#94A3B8'
    } else {
        $EasyPanel.Visibility     = 'Collapsed'
        $AdvancedPanel.Visibility = 'Visible'
        $BtnModeAdvanced.Background = & $Brush '#2563EB'
        $BtnModeAdvanced.Foreground = & $Brush '#FFFFFF'
        $BtnModeEasy.Background     = [Windows.Media.Brushes]::Transparent
        $BtnModeEasy.Foreground     = & $Brush '#94A3B8'
    }
}

$WriteLog = {
    param([string]$Message)
    $ts = (Get-Date).ToString('HH:mm:ss')
    $TxtLog.AppendText("[$ts] $Message`r`n")
    $TxtLog.ScrollToEnd()
    $clean = $Message -replace '^\[(OK|INFO|WARN|ERROR|Layer \d|DRY RUN)\]\s*', ''
    $EasyStatusLine.Text = $clean
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
}

$SetBadge = {
    param($BorderCtrl, $TextCtrl, [string]$Text, [string]$BgHex, [string]$FgHex)
    $BorderCtrl.Background = & $Brush $BgHex
    $TextCtrl.Text         = $Text
    $TextCtrl.Foreground   = & $Brush $FgHex
}

$RefreshUI = {
    $d       = Get-Diagnostics
    $lockPln = Get-LockUpdatesPlan
    $optPln  = Get-OptimizeWindowsPlan
    $script:LastDiag    = $d
    $script:LastLockPln = $lockPln
    $script:LastOptPln  = $optPln

    # Admin pill
    if ($d.IsAdmin) {
        $AdminBadge.Background  = & $Brush '#103629'
        $AdminBadge.BorderBrush = & $Brush '#1C5B42'
        $AdminDot.Fill          = & $Brush '#34D399'
        $AdminBadgeText.Text    = 'Admin Ready'
        $AdminBadgeText.Foreground = & $Brush '#86EFAC'
    } else {
        $AdminBadge.Background  = & $Brush '#3B151B'
        $AdminBadge.BorderBrush = & $Brush '#7F1D1D'
        $AdminDot.Fill          = & $Brush '#F87171'
        $AdminBadgeText.Text    = 'Read-Only'
        $AdminBadgeText.Foreground = & $Brush '#FCA5A5'
    }

    # Shield & Boost state calculations
    $allTargetsLocked = ($d.TotalLockTargets -gt 0) -and ($d.LockedFolders -eq $d.TotalLockTargets)
    $updatersClean    = ($d.CachedUpgraders.Count -eq 0) -and ($d.ActiveUpdaters.Count -eq 0)
    $shieldFullyOn    = $allTargetsLocked -and $updatersClean -and (-not $lockPln.HasWork)
    $perfBoosted      = (-not $optPln.HasWork)

    # ==================== UPDATE ADVANCED MODE CARDS ====================
    if ($d.HasGameLoop7 -and $d.Classic) {
        $TxtEdition.Text = "Both 7.0 & Classic Found"
        $TxtEdition.Foreground = & $Brush '#FBBF24'
        $TxtEditionSub.Text = "7.0: $($d.GameLoop7Dirs -join ', ')`nClassic: $($d.Classic.Root)"
    } elseif ($d.HasGameLoop7) {
        $TxtEdition.Text = "GameLoop 7.0 Installed"
        $TxtEdition.Foreground = & $Brush '#F87171'
        $TxtEditionSub.Text = "Paths: $($d.GameLoop7Dirs -join ', ')`nService: $($d.GameLoop7Svc)"
    } elseif ($d.Classic) {
        $TxtEdition.Text = "Classic GameLoop Active"
        $TxtEdition.Foreground = & $Brush '#4ADE80'
        $eng = if ($d.Classic.HasEngineUI) { "Engine UI ready" } else { "Waiting for first game install" }
        $TxtEditionSub.Text = "$($d.Classic.Root)`n$eng"
    } else {
        $TxtEdition.Text = "No GameLoop Installed"
        $TxtEdition.Foreground = & $Brush '#94A3B8'
        $TxtEditionSub.Text = if ($d.ClassicInstaller) { "Installer: $(Split-Path -Leaf $d.ClassicInstaller)" } else { "Ready for fresh Classic install" }
    }

    if ($allTargetsLocked -and $updatersClean) {
        $TxtShield.Text = if ($d.StoreFwBlocked) { "Protected (Strict Store Block)" } else { "Protected (Games Online)" }
        $TxtShield.Foreground = & $Brush '#4ADE80'
    } elseif ($d.LockedFolders -gt 0) {
        $TxtShield.Text = "Partially Protected"
        $TxtShield.Foreground = & $Brush '#FBBF24'
    } else {
        $TxtShield.Text = "Unprotected (7.0 Can Auto-Install)"
        $TxtShield.Foreground = & $Brush '#F87171'
    }
    $TxtShieldSub.Text = "NTFS Locks: $($d.LockedFolders)/$($d.TotalLockTargets) | Active Updaters: $($d.ActiveUpdaters.Count + $d.CachedUpgraders.Count)`nStore: $($d.FirewallStatus)"

    if ($d.Classic) {
        $BtnLaunchClassic.Content = 'Launch Classic (Installed)'
    } else {
        $BtnLaunchClassic.Content = 'Install Classic GameLoop'
    }

    if ($d.StoreFwBlocked) {
        $BtnToggleStrict.Content    = 'Re-Allow Store Downloads'
        $BtnToggleStrict.Background = & $Brush '#0284C7'
    } else {
        $BtnToggleStrict.Content    = 'Strict Block Store (Opt.)'
        $BtnToggleStrict.Background = & $Brush '#D97706'
    }

    # Build generic lag/manual advice list
    $advIssues  = New-Object System.Collections.Generic.List[string]
    $manualTips = New-Object System.Collections.Generic.List[string]
    if ($d.GameDvrEnabled) { $advIssues.Add("Xbox Game DVR is ON (adds frame spikes)") }
    if ($d.HvciEnabled) {
        $advIssues.Add("Windows Memory Integrity (HVCI) is ON (adds virtualization overhead)")
        $manualTips.Add("Turn OFF Windows Memory Integrity (Core Isolation) for lower emulator CPU latency (use the 'Core Isolation' button above).")
    }
    if ($d.VirtAppsRunning.Count -gt 0) {
        $advIssues.Add("Other VM/container app running ($($d.VirtAppsRunning -join ', ')) — close before gaming")
        $manualTips.Add("Close $($d.VirtAppsRunning -join ', ') before playing — running another VM alongside GameLoop causes micro-stutters.")
    }
    if ($d.RamUsedPercent -ge 75) {
        $advIssues.Add("High host RAM usage ($($d.RamUsedPercent)% of $($d.TotalRamGb) GB) — close heavy background apps/browsers")
        $manualTips.Add("Host RAM is $($d.RamUsedPercent)% full ($($d.TotalRamGb) GB total) — closing unused browser tabs/apps frees headroom.")
    }
    if ($d.OverlayApps.Count -gt 0) {
        $advIssues.Add("Background GPU/capture overlay running: $($d.OverlayApps -join ', ')")
        $manualTips.Add("Background overlay detected ($($d.OverlayApps -join ', ')) — pause or close if you notice mid-game frame drops.")
    }
    if ($d.Classic -and $d.Classic.HasEngineUI -and $d.GpuProfile.HasDiscreteGpu -and (-not $d.ClassicGpuPinned)) {
        $advIssues.Add("Classic emulator not yet pinned to discrete GPU ($($d.GpuProfile.DiscreteGpus -join ', '))")
    }
    if ($d.Classic -and $d.Classic.HasEngineUI -and $d.DisplayScalingPct -gt 100 -and (-not $d.ClassicDpiFixed)) {
        $advIssues.Add("Display scaling is $($d.DisplayScalingPct)% — apply High-DPI fix to prevent blurry rendering")
    }

    if ($advIssues.Count -eq 0) {
        $TxtPerf.Text = "Optimal"
        $TxtPerf.Foreground = & $Brush '#4ADE80'
        $TxtPerfSub.Text = "RAM: $($d.RamUsedPercent)% | DPI: $($d.DisplayScalingPct)% | Clean"
        $TxtAdvisor.Text = "• All core checks look great on this PC!`n• In Classic GameLoop Settings -> Game, set Gaming Resolution to Ultra HD 2K.`n• If using a 1000 Hz+ gaming mouse and camera stutters, lower polling rate to 250-500 Hz."
    } else {
        $TxtPerf.Text = "$($advIssues.Count) Lag Factor(s) Found"
        $TxtPerf.Foreground = & $Brush '#FBBF24'
        $TxtPerfSub.Text = "RAM: $($d.RamUsedPercent)% | DPI: $($d.DisplayScalingPct)% | GPUs: $($d.GpuProfile.AllGpus.Count)"
        $TxtAdvisor.Text = ($advIssues | ForEach-Object { "• $_" }) -join "`n"
    }

    # ==================== UPDATE EASY MODE DASHBOARD ====================
    # Card 1: Edition
    if ($d.HasGameLoop7) {
        & $SetBadge $EasyBadge1 $EasyBadge1Text '7.0 Detected' '#3F161D' '#FCA5A5'
        $EasyDesc1.Text = "GameLoop 7.0 ('Androws') is installed on your PC. Remove it cleanly so you can enjoy Classic GameLoop's sharp 2K mode and smooth mouse control."
        $EasySub1.Text  = "Found in: $($d.GameLoop7Dirs -join ', ')"
        $BtnEasyCard1.Content    = 'Remove GameLoop 7.0'
        $BtnEasyCard1.Background = & $Brush '#DC2626'
    } elseif ($d.Classic) {
        & $SetBadge $EasyBadge1 $EasyBadge1Text 'Classic Ready' '#0F3626' '#6EE7B7'
        $EasyDesc1.Text = "Classic GameLoop is installed and ready! Remember to set Gaming Resolution to Ultra HD 2K inside GameLoop Settings -> Game."
        $EasySub1.Text  = if ($d.Classic.HasEngineUI) { "Installed at: $($d.Classic.Root)" } else { "Installed at: $($d.Classic.Root) (open to install your first game)" }
        $BtnEasyCard1.Content    = 'Launch Classic GameLoop'
        $BtnEasyCard1.Background = & $Brush '#2563EB'
    } else {
        & $SetBadge $EasyBadge1 $EasyBadge1Text 'Not Installed' '#1E293B' '#CBD5E1'
        $EasyDesc1.Text = "No GameLoop installation detected yet. Launch your Classic installer to get started cleanly."
        $EasySub1.Text  = if ($d.ClassicInstaller) { "Local setup found: $(Split-Path -Leaf $d.ClassicInstaller)" } else { "Will open gameloop.com to download" }
        $BtnEasyCard1.Content    = 'Install Classic GameLoop'
        $BtnEasyCard1.Background = & $Brush '#0284C7'
    }

    # Card 2: Update Shield
    if ($shieldFullyOn) {
        & $SetBadge $EasyBadge2 $EasyBadge2Text 'Protected' '#0F3626' '#6EE7B7'
        $EasyDesc2.Text = "Forced GameLoop 7.0 auto-updates are completely blocked — and your PUBG Mobile & game downloads stay 100% online!"
        $EasySub2.Text  = "All $($d.TotalLockTargets) folders locked • 0 active 7.0 updaters"
        $BtnEasyCard2.Content    = 'Shield Is Active'
        $BtnEasyCard2.Background = & $Brush '#166534'
    } else {
        $badgeLabel = if ($d.LockedFolders -gt 0) { 'Almost Done' } else { 'Needs Shield' }
        & $SetBadge $EasyBadge2 $EasyBadge2Text $badgeLabel '#3E2B10' '#FCD34D'
        $EasyDesc2.Text = "Stops GameLoop from silently upgrading you back to 7.0 — while PUBG Mobile & all other game updates continue working normally."
        $pendingUpd = $d.ActiveUpdaters.Count + $d.CachedUpgraders.Count
        $EasySub2.Text  = "$($d.LockedFolders)/$($d.TotalLockTargets) locations locked • $pendingUpd updater(s) ready to neutralize"
        $BtnEasyCard2.Content    = 'Turn On Update Shield'
        $BtnEasyCard2.Background = & $Brush '#059669'
    }

    # Card 3 (Optional Extra): Auto-Detected PC Specs & Spec-Matched Optimizer
    $sp = $d.PcSpecs
    $EasyTierBadgeText.Text = "$($sp.Tier) PC Detected"
    $EasySpecCpu.Text       = $sp.CpuName
    $EasySpecCpuSub.Text    = "$($sp.PhysicalCores) Cores / $($sp.LogicalCores) Threads"
    $EasySpecGpu.Text       = $sp.PrimaryGpuName
    $EasySpecGpuSub.Text    = "$(if ($sp.HasDiscreteGpu) { 'Discrete' } else { 'Integrated' }) • $($sp.PrimaryVramGb) GB VRAM"
    $EasySpecRam.Text       = "$($sp.TotalRamGb) GB Total"
    $EasySpecRamSub.Text    = "$($sp.RamUsedPercent)% currently in use"
    $EasySpecMon.Text       = "$($sp.MonitorWidth)x$($sp.MonitorHeight) @ $($sp.MonitorHz) Hz"
    $EasySpecMonSub.Text    = "Windows DPI scaling: $($sp.DisplayScalingPct)%"

    $profileLine = "Tailored for your $($sp.Tier) PC: $($sp.RecommendedCpu) vCPU • $($sp.RecommendedRamMb) MB RAM • $($sp.RecommendedWidth)x$($sp.RecommendedHeight) ($($sp.RecommendedDpi) DPI) • Game Res: $($sp.RecommendedGameRes) ($($sp.RecommendedFps))"

    if ($perfBoosted) {
        & $SetBadge $EasyBadge3 $EasyBadge3Text 'Applied' '#0F3626' '#6EE7B7'
        $EasyDesc3.Text = $profileLine
        $EasySub3.Text  = "All recommended spec-matched Engine & Windows optimizations are already active on this PC."
        $BtnEasyCard3.Content    = 'Optimization Active'
        $BtnEasyCard3.Background = & $Brush '#166534'
    } else {
        & $SetBadge $EasyBadge3 $EasyBadge3Text 'Optional' '#2B1B4A' '#C4B5FD'
        $EasyDesc3.Text = $profileLine
        $EasySub3.Text  = "Completely optional — $($optPln.Summary.Count) spec-matched Engine & Windows tweak(s) available (preview shown before applying)."
        $BtnEasyCard3.Content    = 'Apply Optional Optimization'
        $BtnEasyCard3.Background = & $Brush '#7C3AED'
    }

    # Hero Banner Smart Summary (PRIMARY MISSION = BLOCK GAMELOOP 7.0 BETA AUTO-UPDATES!)
    if ($d.HasGameLoop7) {
        $EasyHeroCircle.Background  = & $Brush '#3B151B'
        $EasyHeroCircle.BorderBrush = & $Brush '#EF4444'
        $EasyHeroIcon.Fill          = & $Brush '#F87171'
        $EasyHeroTitle.Text = "GameLoop 7.0 Beta Detected — Switch Back to Classic"
        $EasyHeroSub.Text   = "Remove buggy GameLoop 7.0 safely in one click without touching your Classic installer, then block forced 7.0 upgrades forever."
        $BtnEasyFixAll.Content    = 'Remove 7.0 Beta Now'
        $BtnEasyFixAll.Background = & $Brush '#DC2626'
    } elseif (-not $d.Classic) {
        $EasyHeroCircle.Background  = & $Brush '#162744'
        $EasyHeroCircle.BorderBrush = & $Brush '#3B82F6'
        $EasyHeroIcon.Fill          = & $Brush '#60A5FA'
        $EasyHeroTitle.Text = "Ready for a Clean Classic GameLoop Install"
        $EasyHeroSub.Text   = "No GameLoop 7.0 beta found! Install Classic GameLoop first, or turn on the 7.0 update blocker now so it can never auto-upgrade."
        $BtnEasyFixAll.Content    = 'Install Classic GameLoop'
        $BtnEasyFixAll.Background = & $Brush '#2563EB'
    } elseif (-not $shieldFullyOn) {
        $EasyHeroCircle.Background  = & $Brush '#36260E'
        $EasyHeroCircle.BorderBrush = & $Brush '#F59E0B'
        $EasyHeroIcon.Fill          = & $Brush '#FBBF24'
        $EasyHeroTitle.Text = "Classic GameLoop Needs 7.0 Beta Update Protection"
        $EasyHeroSub.Text   = "Block forced upgrades to the new 7.0 beta in one click — PUBG Mobile & all other game downloads/updates stay 100% online!"
        $BtnEasyFixAll.Content    = 'Block 7.0 Updates (1-Click)'
        $BtnEasyFixAll.Background = & $Brush '#059669'
    } else {
        $EasyHeroCircle.Background  = & $Brush '#0E3324'
        $EasyHeroCircle.BorderBrush = & $Brush '#10B981'
        $EasyHeroIcon.Fill          = & $Brush '#34D399'
        $EasyHeroTitle.Text = "Protected! Classic GameLoop Cannot Auto-Update to 7.0 Beta"
        $EasyHeroSub.Text   = "All forced 7.0 beta upgrade vectors are blocked, and PUBG Mobile / game downloads stay 100% online."
        $BtnEasyFixAll.Content    = 'Launch Classic GameLoop'
        $BtnEasyFixAll.Background = & $Brush '#2563EB'
    }

    # Friendly Tips Sub-row
    if ($manualTips.Count -gt 0) {
        $EasyTipsTitle.Text = "Optional PC Tips ($($manualTips.Count) detected)"
        $EasyTipsBody.Text  = ($manualTips | ForEach-Object { "• $_" }) -join "`n"
        $BtnEasyOpenHvci.Visibility = if ($d.HvciEnabled) { 'Visible' } else { 'Collapsed' }
    } else {
        $EasyTipsTitle.Text = "Recommended In-App Game Settings for Your $($sp.Tier) PC"
        $EasyTipsBody.Text  = "• In Classic GameLoop Settings -> Game, set Gaming Resolution to $($sp.RecommendedGameRes) (target $($sp.RecommendedFps)).`n• If using a 1000 Hz+ gaming mouse and camera ever hitches, try lowering Report Rate to 250-500 Hz."
        $BtnEasyOpenHvci.Visibility = 'Collapsed'
    }
}

# ==================== SHARED ACTION HANDLERS ====================
$DoRemove7 = {
    $plan = Get-RemoveGameLoop7Plan
    if (-not $plan.HasWork) {
        & $WriteLog "[OK] GameLoop 7.0 was not detected on this PC — nothing to remove."
        [System.Windows.MessageBox]::Show("GameLoop 7.0 ('Androws') was not detected on this PC. Nothing was changed.", "Nothing To Remove", 'OK', 'Information') | Out-Null
        return
    }
    $preview = ($plan.Summary | ForEach-Object { "• $_" }) -join "`n"
    $ans = [System.Windows.MessageBox]::Show(
        "Detected the following GameLoop 7.0 items on this PC:`n`n$preview`n`nYour Classic installer and cached classic packages will NOT be touched.`n`nProceed with removal?",
        "Confirm Remove GameLoop 7.0", 'YesNo', 'Warning')
    if ($ans -eq 'Yes') {
        Invoke-RemoveGameLoop7 -Log $WriteLog | Out-Null
        & $RefreshUI
    }
}

$DoLaunchClassicInstaller = {
    $existingClassic = Find-ClassicGameLoop
    if ($existingClassic) {
        $ans = [System.Windows.MessageBox]::Show(
            "Classic GameLoop is ALREADY installed on this PC:`n$($existingClassic.Root)`n`nYou do NOT need to download or reinstall it!`n`nClick 'Yes' to launch your existing Classic GameLoop now (or 'No' to cancel).",
            "Classic GameLoop Already Installed", 'YesNo', 'Information')
        if ($ans -eq 'Yes') {
            & $DoLaunchClassicApp
        }
        return
    }
    $inst = Find-ClassicInstaller
    if ($inst) {
        $ans = [System.Windows.MessageBox]::Show(
            "Found local Classic GameLoop installer:`n$inst`n`nLaunch this installer now?",
            "Launch Detected Installer", 'YesNo', 'Question')
        if ($ans -eq 'Yes') {
            & $WriteLog "Launching detected local installer: $inst"
            Start-Process -FilePath $inst
        }
    } else {
        & $WriteLog "No local GLP_installer*.exe found in Downloads/Desktop. Opening gameloop.com..."
        Start-Process "https://www.gameloop.com/"
    }
}

$DoLaunchClassicApp = {
    $classic = Find-ClassicGameLoop
    if ($classic -and $classic.EmulatorExe) {
        & $WriteLog "Launching Classic GameLoop Emulator directly: $($classic.EmulatorExe)"
        Start-Process -FilePath $classic.EmulatorExe -ArgumentList '-vm 100' -WorkingDirectory (Split-Path -Parent $classic.EmulatorExe)
    } elseif ($classic -and $classic.AppMarketExe) {
        & $WriteLog "Launching Classic GameLoop Store: $($classic.AppMarketExe)"
        Start-Process -FilePath $classic.AppMarketExe -WorkingDirectory (Split-Path -Parent $classic.AppMarketExe)
    } else {
        & $DoLaunchClassicInstaller
    }
}

$DoLockUpdates = {
    $plan = Get-LockUpdatesPlan
    if (-not $plan.HasWork) {
        & $WriteLog "[OK] All Anti-7.0 emulator update blocks are already active (game downloads & updates remain online)."
        [System.Windows.MessageBox]::Show("All Anti-GameLoop-7.0 protections are already active on this PC, and game downloads/updates remain 100% online!", "Already Protected", 'OK', 'Information') | Out-Null
        return
    }
    $preview = ($plan.Summary | ForEach-Object { "• $_" }) -join "`n"
    $ans = [System.Windows.MessageBox]::Show(
        "Detected the following Anti-7.0 protections to apply on this PC:`n`n$preview`n`nApply these changes now?",
        "Confirm Update Shield", 'YesNo', 'Question')
    if ($ans -eq 'Yes') {
        Invoke-LockUpdates -Log $WriteLog | Out-Null
        & $RefreshUI
    }
}

$DoOptimizeWindows = {
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
        "Confirm Performance Boost", 'YesNo', 'Question')
    if ($ans -eq 'Yes') {
        Invoke-OptimizeWindows -Log $WriteLog | Out-Null
        & $RefreshUI
    }
}

# ==================== WIRE UP EVENTS ====================
$BtnModeEasy.Add_Click({ & $SetUiMode 'Easy' })
$BtnModeAdvanced.Add_Click({ & $SetUiMode 'Advanced' })
$BtnEasyToAdvanced.Add_Click({ & $SetUiMode 'Advanced' })

$BtnRefresh.Add_Click({
    & $WriteLog "Rescanning system..."
    & $RefreshUI
    & $WriteLog "Scan complete — no changes applied."
})

# Easy Mode Primary 1-Click Hero Button (Focused strictly on Primary Mission: Blocking 7.0 Beta Auto-Updates!)
$BtnEasyFixAll.Add_Click({
    $d = $script:LastDiag
    if (-not $d) { & $RefreshUI; $d = $script:LastDiag }

    if ($d.HasGameLoop7) {
        & $DoRemove7
        return
    }
    if (-not $d.Classic) {
        & $DoLaunchClassicInstaller
        return
    }

    $lockPlan = Get-LockUpdatesPlan
    if ($lockPlan.HasWork) {
        & $DoLockUpdates
    } else {
        & $DoLaunchClassicApp
    }
})

# Easy Mode Step Cards
$BtnEasyCard1.Add_Click({
    if ($script:LastDiag -and $script:LastDiag.HasGameLoop7) { & $DoRemove7 }
    elseif ($script:LastDiag -and $script:LastDiag.Classic)  { & $DoLaunchClassicApp }
    else { & $DoLaunchClassicInstaller }
})
$BtnEasyCard2.Add_Click({ & $DoLockUpdates })
$BtnEasyCard3.Add_Click({ & $DoOptimizeWindows })
$BtnEasyOpenHvci.Add_Click({
    & $WriteLog "Opening Windows Security -> Core Isolation..."
    Start-Process "windowsdefender://coreisolation"
})

# Advanced Mode Controls
$BtnRemove7.Add_Click($DoRemove7)
$BtnLaunchClassic.Add_Click({
    if ($script:LastDiag -and $script:LastDiag.Classic) { & $DoLaunchClassicApp }
    else { & $DoLaunchClassicInstaller }
})
$BtnLockUpdates.Add_Click($DoLockUpdates)
$BtnOptimize.Add_Click($DoOptimizeWindows)

$BtnDryRunAll.Add_Click({
    & $WriteLog "========== PREVIEW DRY RUN (No Changes Applied) =========="
    Invoke-RemoveGameLoop7 -DryRunMode -Log $WriteLog | Out-Null
    Invoke-LockUpdates     -DryRunMode -Log $WriteLog | Out-Null
    Invoke-OptimizeWindows -DryRunMode -Log $WriteLog | Out-Null
    & $WriteLog "========== END DRY RUN PREVIEW =========="
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

$BtnOpenSecurity.Add_Click({
    & $WriteLog "Opening Windows Security -> Core Isolation..."
    Start-Process "windowsdefender://coreisolation"
})

$BtnClearLog.Add_Click({
    $TxtLog.Clear()
})

$BtnCopyLog.Add_Click({
    [System.Windows.Clipboard]::SetText($TxtLog.Text)
    & $WriteLog "Copied activity log to clipboard."
})

$window.Add_Loaded({
    & $SetUiMode 'Easy'
    & $WriteLog "GameLoop Doctor v$($script:AppVersion) ready. Running read-only system scan..."
    & $RefreshUI
    & $WriteLog "Initial scan complete — Easy Mode active. No changes are applied until you confirm."
})

$window.ShowDialog() | Out-Null
