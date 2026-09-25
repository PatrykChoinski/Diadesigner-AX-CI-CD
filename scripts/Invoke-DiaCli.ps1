<#
.SYNOPSIS
    Runs DIADesigner-AX.exe (Delta's build of CODESYS.exe) headless with a
    CODESYS Scripting (IronPython) script and returns its exit code:

        DIADesigner-AX.exe --profile="DIADesigner-AX 1.10" --runscript="<script>.py" --scriptargs:'"<a1>" "<a2>"' --noUI --textPrompts

    Same command line as plain CODESYS - --scriptargs uses a COLON and
    single quotes, the script reads its arguments back via sys.argv.
    --textPrompts keeps confirmation dialogs from silently blocking forever
    under --noUI.
#>
param(
    [string]$DiaExe = "C:\Program Files\Delta Industrial Automation\DIAStudio\DIADesigner-AX 1.10\CODESYS\Common\DIADesigner-AX.exe",
    # Name of the profile file in ...\CODESYS\Profiles (without .profile.xml).
    [string]$Profile = "DIADesigner-AX 1.10",
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][string[]]$ScriptArguments,
    [int]$TimeoutMinutes = 30
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $DiaExe)) {
    throw "DIADesigner-AX not found at $DiaExe"
}

$scriptArgsValue = ($ScriptArguments | ForEach-Object { '"{0}"' -f $_ }) -join ' '
$argumentString = "--profile=`"$Profile`" --runscript=`"$ScriptPath`" --scriptargs:'$scriptArgsValue' --noUI --textPrompts"

$proc = Start-Process -FilePath $DiaExe -ArgumentList $argumentString -PassThru -NoNewWindow
# Touch the handle right away - otherwise Windows PowerShell 5.1 loses the
# exit code of a Start-Process'd process waited on via WaitForExit(timeout)
# and ExitCode comes back empty.
$null = $proc.Handle
$finished = $proc.WaitForExit([int]([TimeSpan]::FromMinutes($TimeoutMinutes).TotalMilliseconds))
if (-not $finished) {
    try { taskkill /T /F /PID $proc.Id 2>&1 | Out-Null } catch {}
    throw "DIADesigner-AX did not finish '$ScriptPath' within $TimeoutMinutes minute(s) (most likely stuck on a dialog)."
}
return $proc.ExitCode
