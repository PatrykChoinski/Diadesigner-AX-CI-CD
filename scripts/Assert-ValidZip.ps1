<#
.SYNOPSIS
    Sanity-checks a downloaded ZIP before extracting it: fails fast with a
    clear message instead of a cryptic extraction error when the download
    actually saved an HTML error/login page instead of the real archive.
#>
param(
    [Parameter(Mandatory = $true)][string]$Path
)

$ErrorActionPreference = "Stop"

$item = Get-Item -Path $Path
if ($item.Length -lt 1MB) {
    $preview = Get-Content -Path $Path -TotalCount 20 -ErrorAction SilentlyContinue
    throw @"
'$Path' is only $($item.Length) bytes - too small to be a real installer
archive. The download most likely returned an HTML/error page instead of
the binary. First lines of the file:
$($preview -join "`n")
"@
}

$stream = [System.IO.File]::OpenRead($item.FullName)
try {
    $b0 = $stream.ReadByte(); $b1 = $stream.ReadByte()
} finally {
    $stream.Dispose()
}
if ($b0 -ne 0x50 -or $b1 -ne 0x4B) {
    # "PK" magic number every ZIP file starts with.
    throw "'$Path' does not start with the 'PK' zip signature - it is not a valid .zip (got bytes: $b0,$b1)."
}

Write-Host "$Path looks like a valid zip archive ($([math]::Round($item.Length / 1MB, 1)) MB)."
