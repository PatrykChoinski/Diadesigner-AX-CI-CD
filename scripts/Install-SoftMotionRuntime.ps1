<#
.SYNOPSIS
    Installs (if needed) and starts CODESYS Control Win V3 x64 SoftMotion
    3.5.18.50 - the soft-PLC bundled with DIADesigner-AX - on this machine,
    plus the CODESYS Gateway the IDE talks to it through.

.DESCRIPTION
    DIADesigner-AX ships the runtime as a separate component
    (Redist\CODESYS_CtrlWin_64-3.5.18.50-Latest.zip, InstallShield MSI).
    Delta's installer runs it as
        msiexec /i "CODESYS Control Win 64 3.5.18.50.msi" SETUPEXEDIR=<dir>
    and the Start Menu entry "CODESYS SoftMotion Win 64" launches it as
        CODESYSControlService.exe -d "CODESYSSoftMotion.cfg"
    i.e. as a console process (-d), with the SoftMotion configuration -
    not as a Windows service. This script does exactly that, in the
    background; its log goes to StdLogger.csv in the runtime's working
    directory (CmpLog file backend, switched on by this script).

    Before starting it, device user management is made optional
    (SECURITY.UserMgmtEnforce=NO in the runtime's CODESYSSoftMotion.cfg):
    CODESYS Control >= SP17 otherwise demands creating an admin user on the
    first engineering login, which headless CI can't answer.

.PARAMETER BundleDir
    Directory the DIADesigner-AX-x64-<version>.zip bundle was extracted to.
    Only needed when the runtime isn't installed yet.
#>
param(
    [string]$BundleDir = "",
    [string]$RuntimeDir = "C:\Program Files\Delta Industrial Automation\DIAStudio\DIADesigner-AX\CODESYS Win Control\3.5.18.50\GatewayPLC",
    [string]$GatewayDir = "C:\Program Files\Delta Industrial Automation\DIAStudio\DIADesigner-AX 1.10\GatewayPLC",
    [string]$LogDir = (Join-Path $PSScriptRoot "..\reports"),
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogDir = (Resolve-Path $LogDir).Path
$rteExe = Join-Path $RuntimeDir "CODESYSControlService.exe"
$rteCfg = "CODESYSSoftMotion.cfg"

# --- install ---------------------------------------------------------------
if (-not (Test-Path $rteExe)) {
    if (-not $BundleDir) {
        throw "$rteExe not found and no -BundleDir given to install it from."
    }
    $zip = Get-ChildItem -Path $BundleDir -Recurse -Filter "CODESYS_CtrlWin_64-*.zip" | Select-Object -First 1
    if (-not $zip) {
        throw "Redist\CODESYS_CtrlWin_64-*.zip not found under '$BundleDir'."
    }
    $msiDir = Join-Path $zip.DirectoryName "CtrlWin-msi"
    & (Join-Path $PSScriptRoot "Expand-Zip.ps1") -ZipPath $zip.FullName -DestinationDir $msiDir
    $msi = Get-ChildItem -Path $msiDir -Filter "*.msi" | Select-Object -First 1
    Write-Host "== Installing $($msi.Name) =="
    $msiLog = Join-Path $LogDir "install-softmotion-rte.msi.log"
    & (Join-Path $PSScriptRoot "Start-SilentInstall.ps1") -InstallerPath "$env:SystemRoot\System32\msiexec.exe" -TimeoutMinutes 20 -ArgumentList @(
        "/i", "`"$($msi.FullName)`"",
        "SETUPEXEDIR=`"$msiDir`"",
        "/qn", "/norestart",
        "/l*v", "`"$msiLog`""
    )
    if (-not (Test-Path $rteExe)) {
        throw "Install reported success but $rteExe was not found - check $msiLog."
    }
} else {
    Write-Host "SoftMotion runtime already installed at $RuntimeDir."
}

function Start-Detached([string]$exe, [string]$arguments, [string]$workingDir) {
    # Win32_Process.Create instead of Start-Process: the new process gets no
    # inherited handles. A long-running child that inherits this script's
    # stdout/stderr pipe keeps a CI step (or any caller reading our output)
    # waiting for EOF long after this script has finished.
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine      = "`"$exe`" $arguments"
        CurrentDirectory = $workingDir
    }
    if ($r.ReturnValue -ne 0) { throw "Win32_Process.Create failed for '$exe' (code $($r.ReturnValue))" }
    return $r.ProcessId
}

# --- gateway ---------------------------------------------------------------
function Test-GatewayListening {
    [bool](Get-NetTCPConnection -LocalPort 1217 -State Listen -ErrorAction SilentlyContinue)
}

if (-not (Test-GatewayListening)) {
    $gwService = Get-Service | Where-Object { $_.DisplayName -like "CODESYS Gateway*" } | Select-Object -First 1
    if ($gwService) {
        Write-Host "Starting gateway service '$($gwService.Name)'"
        Start-Service -Name $gwService.Name
    } else {
        Write-Host "No gateway service installed - starting $GatewayDir\GatewayService.exe -d"
        $gwPid = Start-Detached (Join-Path $GatewayDir "GatewayService.exe") "-d" $GatewayDir
        Write-Host "Started gateway (PID $gwPid)"
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (Test-GatewayListening)) {
        if ((Get-Date) -gt $deadline) { throw "CODESYS Gateway is not listening on TCP 1217 after ${TimeoutSeconds}s." }
        Start-Sleep -Seconds 2
    }
}
Write-Host "CODESYS Gateway is listening on TCP 1217."

# --- runtime -----------------------------------------------------------------
function Stop-SoftMotionRuntime {
    Get-CimInstance Win32_Process -Filter "Name = 'CODESYSControlService.exe'" |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath -ieq $rteExe } |
        ForEach-Object {
            Write-Host "Stopping runtime process $($_.ProcessId)"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    Start-Sleep -Seconds 2
}

function Start-SoftMotionRuntime {
    # Console output is not captured - it's block-buffered and lost on kill
    # anyway; the runtime log comes from CmpLog's file backend
    # (StdLogger.csv in the working dir, see Enable-FileLogger).
    $rtePid = Start-Detached $rteExe "-d `"$rteCfg`"" $RuntimeDir
    Write-Host "Started SoftMotion runtime (PID $rtePid)"
}

function Get-RuntimeWorkDir {
    # GatewayPLC\CODESYSSoftMotion.cfg only redirects to the real working
    # directory under ProgramData, where the full config/log/PlcLogic live.
    $stub = Get-Content -Path (Join-Path $RuntimeDir $rteCfg)
    $line = $stub | Where-Object { $_ -match '^Windows\.WorkingDirectory=' } | Select-Object -First 1
    if (-not $line) { throw "No Windows.WorkingDirectory in $RuntimeDir\$rteCfg" }
    return ($line -replace '^Windows\.WorkingDirectory=', '').Trim()
}

function Set-UserMgmtOptional([string]$cfgPath) {
    $content = [System.Collections.Generic.List[string]](Get-Content -Path $cfgPath)
    if ($content -contains "SECURITY.UserMgmtEnforce=NO") { return $false }
    $idx = $content.IndexOf(";SECURITY.UserMgmtEnforce=NO")
    if ($idx -ge 0) {
        $content[$idx] = "SECURITY.UserMgmtEnforce=NO"
    } else {
        $sec = $content.IndexOf("[CmpUserMgr]")
        if ($sec -ge 0) {
            $content.Insert($sec + 1, "SECURITY.UserMgmtEnforce=NO")
        } else {
            $content.Add(""); $content.Add("[CmpUserMgr]"); $content.Add("SECURITY.UserMgmtEnforce=NO")
        }
    }
    Set-Content -Path $cfgPath -Value $content -Encoding ascii
    Write-Host "Patched $cfgPath (SECURITY.UserMgmtEnforce=NO)"
    return $true
}

function Enable-FileLogger([string]$cfgPath) {
    # The runtime's console output (-d) is block-buffered and lost when the
    # process is killed, and the audit log doesn't record IEC exceptions -
    # so turn on CmpLog's file backend (shipped commented out in the
    # [CmpLog] section): StdLogger -> SysOut + file, in the working dir.
    $content = [System.Collections.Generic.List[string]](Get-Content -Path $cfgPath)
    $wanted = [ordered]@{
        "Logger.0.Name"             = "StdLogger"
        "Logger.0.Enable"           = "1"
        "Logger.0.MaxEntries"       = "10000"
        "Logger.0.MaxFileSize"      = "1000000"
        "Logger.0.MaxFiles"         = "3"
        "Logger.0.Backend.0.ClassId" = "0x0000010B"
        "Logger.0.Backend.1.ClassId" = "0x00000104"
    }
    $sec = $content.IndexOf("[CmpLog]")
    if ($sec -lt 0) { $content.Add(""); $content.Add("[CmpLog]"); $sec = $content.Count - 1 }
    $changed = $false
    foreach ($key in $wanted.Keys) {
        $line = "$key=$($wanted[$key])"
        $idx = -1
        for ($i = 0; $i -lt $content.Count; $i++) {
            if ($content[$i] -match "^;?$([regex]::Escape($key))=") { $idx = $i; break }
        }
        if ($idx -ge 0) {
            if ($content[$idx] -ne $line) { $content[$idx] = $line; $changed = $true }
        } else {
            $sec++; $content.Insert($sec, $line); $changed = $true
        }
    }
    if ($changed) {
        Set-Content -Path $cfgPath -Value $content -Encoding ascii
        Write-Host "Patched $cfgPath (CmpLog file logger)"
    }
}

function Wait-RuntimeListening {
    # 11740 = CODESYS runtime's TCP block driver port.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (Get-NetTCPConnection -LocalPort 11740 -State Listen -ErrorAction SilentlyContinue)) {
        if ((Get-Date) -gt $deadline) { throw "SoftMotion runtime is not listening on TCP 11740 after ${TimeoutSeconds}s - see $LogDir\softmotion-rte.*.log" }
        Start-Sleep -Seconds 2
    }
}

# Any other CODESYS Control (e.g. a plain Win V3 service) would hold the
# same ports (11740/1740) - stop it so the SoftMotion instance can bind.
Get-Service | Where-Object { $_.DisplayName -like "CODESYS Control*" -and $_.Status -eq "Running" } | ForEach-Object {
    Write-Host "Stopping service '$($_.Name)' (would clash with the SoftMotion runtime's ports)"
    Stop-Service -Name $_.Name -Force
}
Stop-SoftMotionRuntime

$workDir = Get-RuntimeWorkDir
$cfgPath = Join-Path $workDir $rteCfg
if (-not (Test-Path $cfgPath)) {
    # First start ever creates the working directory and its full config.
    Write-Host "No $cfgPath yet - starting the runtime once to create it"
    Start-SoftMotionRuntime | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (Test-Path $cfgPath)) {
        if ((Get-Date) -gt $deadline) { throw "Runtime did not create $cfgPath within ${TimeoutSeconds}s." }
        Start-Sleep -Seconds 2
    }
    Start-Sleep -Seconds 5
    Stop-SoftMotionRuntime
}
Set-UserMgmtOptional $cfgPath | Out-Null
Enable-FileLogger $cfgPath

Start-SoftMotionRuntime | Out-Null
Wait-RuntimeListening
Write-Host "CODESYS Control Win V3 x64 SoftMotion is running (work dir: $workDir)."
