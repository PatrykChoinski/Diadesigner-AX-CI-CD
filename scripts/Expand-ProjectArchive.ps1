<#
.SYNOPSIS
    Unpacks the dependencies bundled in a .projectarchive - device
    descriptions and compiled libraries - into plain files, for
    dia_build.py to install into DIADesigner-AX's repositories.

.DESCRIPTION
    A .projectarchive is a zip. Its entries are named
    "{category guid}\<display name>   <file name>"; the ones used here:

      {0c63867f-...}\<device>   ... .zip    - one device description per
                                             nested zip (device.xml + files)
      {e179ebb1-...}\<library>  <file>.compiled-library*  - compiled library

    Why not projects.open_archive(): on a machine that doesn't have the
    archive's devices/libraries yet (a fresh CI runner) it asks which
    items to install in a dialog, which headless mode cancels - the call
    then just returns None. Installing the files directly via
    device_repository.import_device() / librarymanager.install_library()
    needs no dialog.

    Output layout:
      <DestinationDir>\devices\<n>\...        (nested device zip extracted)
      <DestinationDir>\libraries\<file>.compiled-library*
#>
param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$DestinationDir
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$devicesDir = Join-Path $DestinationDir "devices"
$librariesDir = Join-Path $DestinationDir "libraries"
if (Test-Path $DestinationDir) { Remove-Item -Recurse -Force $DestinationDir }
New-Item -ItemType Directory -Force -Path $devicesDir, $librariesDir | Out-Null

$zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $ArchivePath).Path)
$nDevices = 0
$nLibraries = 0
try {
    foreach ($entry in $zip.Entries) {
        # The real file name is the last whitespace-separated token of the
        # entry name ("...   3s storage.compiled-library-v3" has a space in
        # it, so split on the 3+ space separator instead).
        $fileName = ($entry.FullName -split '\s{3,}')[-1]

        if ($fileName -match '\.compiled-library(-v3|-ge33)?$') {
            $target = Join-Path $librariesDir $fileName
            $i = 1
            while (Test-Path $target) {
                $target = Join-Path $librariesDir ("{0}_{1}{2}" -f [IO.Path]::GetFileNameWithoutExtension($fileName), $i, [IO.Path]::GetExtension($fileName))
                $i++
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target)
            $nLibraries++
        } elseif ($fileName -eq '.zip' -or $entry.FullName -match '\.zip$') {
            $nDevices++
            $dir = Join-Path $devicesDir ("{0:D3}" -f $nDevices)
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $stream = $entry.Open()
            try {
                $inner = New-Object System.IO.Compression.ZipArchive($stream)
                foreach ($ie in $inner.Entries) {
                    if (-not $ie.Name) { continue }
                    $dest = Join-Path $dir ($ie.FullName -replace '/', '\')
                    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($ie, $dest, $true)
                }
                $inner.Dispose()
            } finally {
                $stream.Dispose()
            }
            # Keep the display name for the build log.
            Set-Content -Path (Join-Path $dir "_name.txt") -Value ($entry.FullName -split '\\', 2)[-1] -Encoding utf8
        }
    }
} finally {
    $zip.Dispose()
}

Write-Host "Extracted $nDevices device description(s) and $nLibraries librar(y/ies) from $ArchivePath to $DestinationDir"
