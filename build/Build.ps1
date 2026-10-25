<#
.SYNOPSIS
    Builds dist\ByteCut.exe. Needs nothing beyond Windows 10/11 itself.

.DESCRIPTION
    Uses the C# compiler that ships with Windows (.NET Framework 4.x csc.exe) to compile
    launcher\Launcher.cs + src\Native.cs, embeds src\Core.ps1 and src\ByteCut.ps1
    as resources, and sets the icon and version info. Runs the stress test first unless
    -SkipTests is given.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build\Build.ps1
    powershell -ExecutionPolicy Bypass -File build\Build.ps1 -SkipTests
#>
param([switch]$SkipTests)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$src  = Join-Path $repo 'src'
$dist = Join-Path $repo 'dist'
$obj  = Join-Path $PSScriptRoot 'obj'
New-Item -ItemType Directory -Force $dist, $obj | Out-Null

# Version comes from the app script
$m = Select-String -Path (Join-Path $src 'ByteCut.ps1') -Pattern "^\`$AppVersion\s*=\s*'([\d.]+)'" | Select-Object -First 1
if (-not $m) { throw 'Could not find $AppVersion in src\ByteCut.ps1' }
$version = $m.Matches[0].Groups[1].Value
Write-Host "Building ByteCut v$version" -ForegroundColor Cyan

if (-not $SkipTests) {
    Write-Host "`n> Stress test" -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tests\StressTest.ps1') -Apps 150
    if ($LASTEXITCODE -ne 0) { throw 'Stress test failed - not building.' }
}

$icon = Join-Path $repo 'assets\app.ico'
if (-not (Test-Path $icon)) { & (Join-Path $PSScriptRoot 'New-Icon.ps1') -Out $icon }

$asmInfo = Join-Path $obj 'AssemblyInfo.cs'
@"
using System.Reflection;
[assembly: AssemblyTitle("ByteCut")]
[assembly: AssemblyDescription("ByteCut - free up disk space by clearing app cache, temp and log files")]
[assembly: AssemblyCompany("Inzamam Islam")]
[assembly: AssemblyProduct("ByteCut")]
[assembly: AssemblyCopyright("Copyright (c) $((Get-Date).Year) Inzamam Islam - MIT License")]
[assembly: AssemblyVersion("$version.0")]
[assembly: AssemblyFileVersion("$version.0")]
"@ | Set-Content $asmInfo -Encoding UTF8

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw '.NET Framework 4 C# compiler (csc.exe) not found.' }
$sma = [PSObject].Assembly.Location          # System.Management.Automation.dll (Windows PowerShell 5.1)
$exe = Join-Path $dist 'ByteCut.exe'

Write-Host "`n> Compiling" -ForegroundColor Cyan
& $csc /nologo /target:winexe /platform:anycpu /optimize+ "/out:$exe" "/win32icon:$icon" `
    "/reference:$sma" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll `
    "/resource:$(Join-Path $src 'Core.ps1'),Core.ps1" `
    "/resource:$(Join-Path $src 'ByteCut.ps1'),ByteCut.ps1" `
    (Join-Path $repo 'launcher\Launcher.cs') (Join-Path $src 'Native.cs') $asmInfo
if ($LASTEXITCODE -ne 0) { throw "csc.exe failed with exit code $LASTEXITCODE" }

$hash = (Get-FileHash $exe -Algorithm SHA256).Hash
"$hash  ByteCut.exe" | Set-Content (Join-Path $dist 'ByteCut.exe.sha256') -Encoding ASCII
$size = (Get-Item $exe).Length
Write-Host ("`nBuilt {0}  ({1:N0} KB)`nSHA256 {2}" -f $exe, ($size / 1KB), $hash) -ForegroundColor Green
