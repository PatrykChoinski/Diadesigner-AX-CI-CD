<#
.SYNOPSIS
    Runs an installer (an .exe, or msiexec.exe for an .msi) with a hard
    timeout, so a wrong silent-install switch (installer falls back to a UI
    nobody can click in headless CI) fails the job after a bounded wait
    instead of hanging until the whole workflow run times out.
#>
param(
    [Parameter(Mandatory = $true)][string]$InstallerPath,
    [Parameter(Mandatory = $true)][string[]]$ArgumentList,
    [int]$TimeoutMinutes = 40,
    # Extra exit codes to treat as success (e.g. 1638 = "a newer version
    # of this product is already installed" for the VC++ redistributables
    # that GitHub's windows runners already ship).
    [int[]]$ExtraSuccessCodes = @()
)

$ErrorActionPreference = "Stop"

Write-Host "Running: $InstallerPath $($ArgumentList -join ' ')"
$proc = Start-Process -FilePath $InstallerPath -ArgumentList $ArgumentList -PassThru
# Cache the handle - otherwise Windows PowerShell 5.1 can lose ExitCode.
$null = $proc.Handle
$finished = $proc.WaitForExit([int]([TimeSpan]::FromMinutes($TimeoutMinutes).TotalMilliseconds))

if (-not $finished) {
    try { taskkill /T /F /PID $proc.Id 2>&1 | Out-Null } catch {}
    throw "'$InstallerPath' did not finish within $TimeoutMinutes minute(s) - most likely it ignored the silent-install switch(es) '$($ArgumentList -join ' ')' and is waiting on a UI prompt."
}

# 3010/3011 = ERROR_SUCCESS_REBOOT_REQUIRED/INITIATED - irrelevant on a
# single-use CI VM.
$successCodes = @(0, 3010, 3011) + $ExtraSuccessCodes
if ($successCodes -notcontains $proc.ExitCode) {
    throw "'$InstallerPath' exited with code $($proc.ExitCode) (args: $($ArgumentList -join ' '))"
}
if ($proc.ExitCode -ne 0) {
    Write-Host "'$InstallerPath' exited with code $($proc.ExitCode) (treated as success)"
}
