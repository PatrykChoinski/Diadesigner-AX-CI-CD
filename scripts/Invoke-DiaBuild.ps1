<#
.SYNOPSIS
    BUILD stage: installs the device descriptions and libraries bundled in
    the .projectarchive (unpacked by Expand-ProjectArchive.ps1), then
    compiles PilaJednosuportowaSoftmotion.project in DIADesigner-AX
    (headless).
#>
param(
    [string]$ArchivePath = (Join-Path $PSScriptRoot "..\PilaJednosuportowaSoftmotion.projectarchive"),
    [string]$DepsDir = (Join-Path $PSScriptRoot "..\work\prime-deps"),
    [string]$ProjectPath = (Join-Path $PSScriptRoot "..\PilaJednosuportowaSoftmotion.project"),
    [string]$ReportPath = (Join-Path $PSScriptRoot "..\reports\junit-build.xml"),
    # Project encryption password - from the PROJECT_PASSWORD env var (the
    # PROJECT_PASSWORD Actions secret in CI), never hardcoded/committed.
    [string]$Password = $env:PROJECT_PASSWORD
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path (Split-Path $ReportPath) | Out-Null
if (-not $Password) { Write-Warning "PROJECT_PASSWORD is not set - opening the encrypted project will fail." }

$ProjectPath = (Resolve-Path $ProjectPath).Path
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$DepsDir = [System.IO.Path]::GetFullPath($DepsDir)
if (Test-Path $ArchivePath) {
    & (Join-Path $PSScriptRoot "Expand-ProjectArchive.ps1") -ArchivePath $ArchivePath -DestinationDir $DepsDir
} else {
    Write-Warning "No project archive at $ArchivePath - skipping device/library priming."
    $DepsDir = ""
}
Remove-Item -Force $ReportPath -ErrorAction SilentlyContinue

Write-Host "== Compiling $ProjectPath =="
$exit = & (Join-Path $PSScriptRoot "Invoke-DiaCli.ps1") `
    -ScriptPath (Join-Path $PSScriptRoot "dia_build.py") `
    -ScriptArguments @($DepsDir, $ProjectPath, $ReportPath, $Password)

if (Test-Path $ReportPath) {
    Write-Host "== Build report =="
    Get-Content $ReportPath
    if ($env:GITHUB_ACTIONS -eq "true") {
        # One annotation per compile error, shown on the run page itself.
        [xml]$report = Get-Content -Path $ReportPath -Raw
        foreach ($case in @($report.testsuite.testcase)) {
            if (-not $case.failure) { continue }
            foreach ($line in ($case.failure -split "`r?`n")) {
                if ($line -match '^(Fatal error|Error) ') {
                    $escaped = $line -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
                    Write-Host "::error title=DIADesigner-AX compile::$escaped"
                }
            }
        }
    }
} else {
    Write-Warning "No report generated at $ReportPath"
}

if ($exit -ne 0) { throw "Build failed (exit code $exit)" }
Write-Host "Build stage finished successfully."
