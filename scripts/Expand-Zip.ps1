<#
.SYNOPSIS
    Validates and extracts a .zip into a directory. Uses the bsdtar shipped
    with Windows (tar.exe) instead of Expand-Archive - the DIADesigner-AX
    bundle is ~2 GB with a ~1.6 GB zip nested inside, and Expand-Archive
    is several times slower on archives that size.
#>
param(
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [Parameter(Mandatory = $true)][string]$DestinationDir
)

$ErrorActionPreference = "Stop"

& (Join-Path $PSScriptRoot "Assert-ValidZip.ps1") -Path $ZipPath

New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null
Write-Host "Extracting $ZipPath -> $DestinationDir"
& "$env:SystemRoot\System32\tar.exe" -xf $ZipPath -C $DestinationDir
if ($LASTEXITCODE -ne 0) {
    throw "tar.exe failed to extract '$ZipPath' (exit code $LASTEXITCODE)"
}
