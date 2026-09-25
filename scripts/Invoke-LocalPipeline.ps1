<#
.SYNOPSIS
    Runs the same three stages as the CI workflow (build -> deploy -> test)
    on this machine, against an already installed DIADesigner-AX 1.10 and
    CODESYS Control Win V3 x64 SoftMotion 3.5.18.50, then prints the
    consolidated report.

    The project password is taken from the PROJECT_PASSWORD environment
    variable (the CI workflow sets it from the PROJECT_PASSWORD secret):

        $env:PROJECT_PASSWORD = "..."
        ./scripts/Invoke-LocalPipeline.ps1

.NOTES
    Downloads the application to the SoftMotion runtime on THIS machine
    only - the network scan is filtered to this computer's node name, real
    PLCs on the LAN are never touched (see dia_common.configure_device_gateway).
#>
param(
    [int]$ObserveSeconds = 30,
    [switch]$KeepRuntime
)

$ErrorActionPreference = "Stop"
if (-not $env:PROJECT_PASSWORD) {
    $env:PROJECT_PASSWORD = [Environment]::GetEnvironmentVariable("PROJECT_PASSWORD", "User")
}
if (-not $env:PROJECT_PASSWORD) { throw "Set the PROJECT_PASSWORD environment variable first." }

$reports = Join-Path $PSScriptRoot "..\reports"
Get-ChildItem -Path $reports -Filter "junit-*.xml" -ErrorAction SilentlyContinue | Remove-Item -Force

try {
    & (Join-Path $PSScriptRoot "Invoke-DiaBuild.ps1")
    & (Join-Path $PSScriptRoot "Invoke-DiaDeployTest.ps1") -ObserveSeconds $ObserveSeconds -KeepRuntime:$KeepRuntime
}
finally {
    & (Join-Path $PSScriptRoot "Write-Summary.ps1")
}
