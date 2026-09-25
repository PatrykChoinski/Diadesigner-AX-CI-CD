<#
.SYNOPSIS
    DEPLOY + TEST stages: starts CODESYS Control Win V3 x64 SoftMotion on
    this machine (installing it first from -BundleDir if it's missing),
    then - in one DIADesigner-AX online session - downloads the
    application, Starts it and watches it for -ObserveSeconds (default 30):
    it must stay in RUN, with no exception.

    Writes reports\junit-deploy.xml and reports\junit-test.xml; afterwards
    copies the runtime logs to reports\ and stops the runtime.
#>
param(
    [string]$BundleDir = "",
    [string]$ProjectPath = (Join-Path $PSScriptRoot "..\PilaJednosuportowaSoftmotion.project"),
    [string]$ReportsDir = (Join-Path $PSScriptRoot "..\reports"),
    [string]$Password = $env:PROJECT_PASSWORD,
    [int]$ObserveSeconds = 30,
    [string]$RuntimeDir = "C:\Program Files\Delta Industrial Automation\DIAStudio\DIADesigner-AX\CODESYS Win Control\3.5.18.50\GatewayPLC",
    # Leave the runtime running afterwards (local debugging).
    [switch]$KeepRuntime
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $ReportsDir | Out-Null
$ReportsDir = (Resolve-Path $ReportsDir).Path
$ProjectPath = (Resolve-Path $ProjectPath).Path
$deployReport = Join-Path $ReportsDir "junit-deploy.xml"
$testReport = Join-Path $ReportsDir "junit-test.xml"
Remove-Item -Force $deployReport, $testReport -ErrorAction SilentlyContinue
if (-not $Password) { Write-Warning "PROJECT_PASSWORD is not set - opening the encrypted project will fail." }

& (Join-Path $PSScriptRoot "Install-SoftMotionRuntime.ps1") -BundleDir $BundleDir -RuntimeDir $RuntimeDir -LogDir $ReportsDir

# The runtime's real working directory (config, PlcLogic, .Audit*.log) -
# GatewayPLC\CODESYSSoftMotion.cfg only redirects there.
$workDir = ((Get-Content (Join-Path $RuntimeDir "CODESYSSoftMotion.cfg")) |
    Where-Object { $_ -match '^Windows\.WorkingDirectory=' } | Select-Object -First 1) -replace '^Windows\.WorkingDirectory=', ''
$workDir = $workDir.Trim().TrimEnd('\')

try {
    Write-Host "== Login, download, start, then watch for ${ObserveSeconds}s (must stay RUN, no exception) =="
    $exit = & (Join-Path $PSScriptRoot "Invoke-DiaCli.ps1") `
        -ScriptPath (Join-Path $PSScriptRoot "dia_deploy_test.py") `
        -ScriptArguments @($ProjectPath, $deployReport, $testReport, $Password, "$ObserveSeconds", $workDir)

    foreach ($r in $deployReport, $testReport) {
        if (Test-Path $r) {
            Write-Host "== $(Split-Path $r -Leaf) =="
            Get-Content $r
        }
    }
    if (-not (Test-Path $deployReport)) { Write-Warning "No report generated at $deployReport" }

    if ($exit -ne 0) {
        if (-not (Test-Path $testReport)) { throw "Deploy failed (exit code $exit)" }
        throw "Smoke test failed (exit code $exit)"
    }
    Write-Host "Deploy + test stages finished successfully."
}
finally {
    $rteExe = Join-Path $RuntimeDir "CODESYSControlService.exe"
    if (-not $KeepRuntime) {
        Write-Host "== Stopping the SoftMotion runtime =="
        Get-CimInstance Win32_Process -Filter "Name = 'CODESYSControlService.exe'" |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath -ieq $rteExe } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
    }
    if (Test-Path $workDir) {
        # StdLogger*.csv = runtime log (CmpLog file backend), .Audit*.log = audit trail.
        Get-ChildItem -Path $workDir -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*.log" -or $_.Name -like "StdLogger*.csv" } | ForEach-Object {
            $name = "softmotion-rte-" + ($_.Name.TrimStart('.') -replace '\s+', '_')
            Copy-Item $_.FullName -Destination (Join-Path $ReportsDir $name) -Force
        }
    }
}
