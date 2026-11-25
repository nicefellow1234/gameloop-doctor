<#
.SYNOPSIS
    Compiles a zero-dependency standalone GameLoop-Doctor.exe (embeds GameLoop-Doctor.ps1)
    using the built-in Windows .NET Framework 4.x C# compiler (no SDK download required!).
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$csc  = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'

if (-not (Test-Path $csc)) {
    throw "Built-in .NET 4.x C# compiler not found at $csc"
}

$distDir = Join-Path $root 'dist'
if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Path $distDir -Force | Out-Null }

$outExe   = Join-Path $distDir 'GameLoop-Doctor.exe'
$srcCs    = Join-Path $root 'src\Launcher.cs'
$manifest = Join-Path $root 'src\app.manifest'
$psScript = Join-Path $root 'GameLoop-Doctor.ps1'

Write-Host "Building standalone $outExe ..." -ForegroundColor Cyan
& $csc `
    /nologo `
    /target:winexe `
    /platform:anycpu `
    /optimize+ `
    "/win32manifest:$manifest" `
    "/resource:$psScript,GameLoop-Doctor.ps1" `
    "/out:$outExe" `
    $srcCs

if ($LASTEXITCODE -ne 0) { throw "csc.exe failed with exit code $LASTEXITCODE" }

$sizeKb = [math]::Round((Get-Item $outExe).Length / 1KB, 1)
Write-Host "[OK] Built standalone single-file executable: $outExe ($sizeKb KB)" -ForegroundColor Green
