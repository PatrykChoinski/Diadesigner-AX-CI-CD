<#
.SYNOPSIS
    Silently installs DIADesigner-AX (Delta's CODESYS-based IDE) from the
    official DIADesigner-AX-x64-<version>.zip bundle. Idempotent: skips the
    install if DIADesigner-AX.exe already exists.

.DESCRIPTION
    The bundle's Setup.exe is Delta's own WPF "DIAInstaller" with no
    documented silent mode. What it does under the hood is described by
    the package manifests in the bundle's Data\*.zip (Manifest.xml:
    <ExecuteFileName>/<SilentCommandLine>) - it just runs the prerequisite
    installers and then the component MSIs with fixed properties. This
    script replays exactly that, headless:

      CodeMeterRuntime_7.50.exe /ComponentArgs "*":"/qn /norestart"
      vcredist/VC_redist *.exe   /q /norestart
      msiexec /i "DIADesigner-AX 1.10.msi" SETUPEXEDIR=<dir> ARPSYSTEMCOMPONENT=1 /qn

    (from Redist\DIADesigner-AX-x64-<version>.zip). The CODESYS Control
    Win SoftMotion runtime is a separate component, installed by
    Install-SoftMotionRuntime.ps1.

.PARAMETER BundleDir
    Directory the DIADesigner-AX-x64-<version>.zip bundle was extracted to
    (the one containing Setup.exe and Redist\).
#>
param(
    [Parameter(Mandatory = $true)][string]$BundleDir,
    [string]$InstallDir = "C:\Program Files\Delta Industrial Automation\DIAStudio\DIADesigner-AX 1.10",
    [string]$LogDir = (Join-Path $PSScriptRoot "..\reports")
)

$ErrorActionPreference = "Stop"

$diaExe = Join-Path $InstallDir "CODESYS\Common\DIADesigner-AX.exe"
if (Test-Path $diaExe) {
    Write-Host "DIADesigner-AX already present at $diaExe, skipping install."
    return
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogDir = (Resolve-Path $LogDir).Path
$redist = Get-ChildItem -Path $BundleDir -Directory -Recurse -Filter Redist | Select-Object -First 1
if (-not $redist) {
    throw "No Redist\ folder found under '$BundleDir' - is this the extracted DIADesigner-AX bundle?"
}
$redist = $redist.FullName
$silent = Join-Path $PSScriptRoot "Start-SilentInstall.ps1"

Write-Host "== Installing prerequisites =="
# 1638 = a newer version is already installed (GitHub runners ship recent
# VC++ runtimes), 5100 = system requirements not met by this older package
# for the same reason - both mean "nothing to do".
foreach ($vc in "vcredist_x64.exe", "vcredist_x86.exe", "VC_redist.x64.exe", "VC_redist.x86.exe") {
    $path = Join-Path $redist $vc
    if (Test-Path $path) {
        & $silent -InstallerPath $path -ArgumentList @("/q", "/norestart") -TimeoutMinutes 10 -ExtraSuccessCodes @(1638, 5100)
    }
}

if (-not (Get-Service -Name "CodeMeter.exe" -ErrorAction SilentlyContinue)) {
    $cm = Get-ChildItem -Path $redist -Filter "CodeMeterRuntime*.exe" | Select-Object -First 1
    if ($cm) {
        & $silent -InstallerPath $cm.FullName -ArgumentList @('/ComponentArgs', '"*":"/qn /norestart"') -TimeoutMinutes 15
    } else {
        Write-Warning "CodeMeterRuntime*.exe not found in $redist - skipping."
    }
} else {
    Write-Host "CodeMeter runtime already installed."
}

Write-Host "== Extracting the DIADesigner-AX MSI package =="
$innerZip = Get-ChildItem -Path $redist -Filter "DIADesigner-AX-x64-*.zip" | Select-Object -First 1
if (-not $innerZip) {
    throw "Redist\DIADesigner-AX-x64-*.zip not found in '$redist'."
}
$msiDir = Join-Path $redist "DIADesigner-AX-msi"
& (Join-Path $PSScriptRoot "Expand-Zip.ps1") -ZipPath $innerZip.FullName -DestinationDir $msiDir
$msi = Get-ChildItem -Path $msiDir -Filter "DIADesigner-AX*.msi" | Select-Object -First 1
if (-not $msi) {
    throw "No DIADesigner-AX*.msi found in '$msiDir'."
}

Write-Host "== Installing $($msi.Name) =="
$msiLog = Join-Path $LogDir "install-diadesigner-ax.msi.log"
# SETUPEXEDIR points the MSI at its own external .cab files (CODESYS.cab,
# SubFea~1.cab, ...) sitting next to it - same as Delta's installer does.
& $silent -InstallerPath "$env:SystemRoot\System32\msiexec.exe" -TimeoutMinutes 60 -ArgumentList @(
    "/i", "`"$($msi.FullName)`"",
    "SETUPEXEDIR=`"$msiDir`"",
    "ARPSYSTEMCOMPONENT=1",
    "/qn", "/norestart",
    "/l*v", "`"$msiLog`""
)

if (-not (Test-Path $diaExe)) {
    throw "Install reported success but $diaExe was not found - check $msiLog."
}

Write-Host "DIADesigner-AX installed."
