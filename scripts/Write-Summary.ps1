<#
.SYNOPSIS
    Reads whichever of reports/junit-{build,deploy,test}.xml exist and
    writes one Markdown report to $env:GITHUB_STEP_SUMMARY (the run's Job
    Summary) - or to the console when run locally. Safe to call when
    earlier stages never ran (their report just doesn't exist).
#>
param(
    [string]$ReportsDir = (Join-Path $PSScriptRoot "..\reports")
)

$ErrorActionPreference = "Stop"

function Get-JUnitCases {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    [xml]$xml = Get-Content -Path $Path -Raw -Encoding UTF8
    $cases = $xml.testsuite.testcase
    if ($null -eq $cases) { return @() }
    return @($cases)
}

# Plain ASCII in the source (no Polish diacritics) - Windows PowerShell 5.1
# misreads BOM-less UTF-8 sources.
$stages = @(
    @{ Name = "Build (priming z .projectarchive + kompilacja PilaJednosuportowaSoftmotion.project)"; File = "junit-build.xml" }
    @{ Name = "Deploy (SoftMotion Win V3 x64: login / download / start)"; File = "junit-deploy.xml" }
    @{ Name = "Test (RUN przez 30 s, bez STOP / exception)"; File = "junit-test.xml" }
)

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("## DIADesigner-AX CI - raport")
$lines.Add("")
$anyFailure = $false
$anyRan = $false

foreach ($stage in $stages) {
    $cases = Get-JUnitCases -Path (Join-Path $ReportsDir $stage.File)
    if ($null -eq $cases) {
        $lines.Add("### $([char]0x2B1C) $($stage.Name)")
        $lines.Add("_Etap nie zostal uruchomiony (wczesniejszy etap przerwal pipeline)._")
        $lines.Add("")
        continue
    }
    $anyRan = $true
    foreach ($case in $cases) {
        $failure = $case.failure
        $details = $case.'system-out'
        $timeAttr = $case.GetAttribute("time")
        $timeSuffix = if ($timeAttr) { " ($timeAttr s)" } else { "" }
        if ($failure) {
            $anyFailure = $true
            $lines.Add("### $([char]0x274C) $($stage.Name) - $($case.name)$timeSuffix")
            $lines.Add("")
            $lines.Add('```')
            $lines.Add(($failure -replace "`r`n", "`n"))
            $lines.Add('```')
        } else {
            $lines.Add("### $([char]0x2705) $($stage.Name) - $($case.name)$timeSuffix")
            if ($details) {
                $lines.Add("")
                $lines.Add("<details><summary>szczegoly</summary>")
                $lines.Add("")
                $lines.Add('```')
                $lines.Add(($details -replace "`r`n", "`n"))
                $lines.Add('```')
                $lines.Add("</details>")
            }
        }
        $lines.Add("")
    }
}

$verdict = if (-not $anyRan) { "$([char]0x2753) Brak jakichkolwiek raportow - sprawdz logi joba." }
    elseif ($anyFailure) { "$([char]0x274C) Pipeline nie przeszedl - patrz szczegoly bledu wyzej." }
    else { "$([char]0x2705) Wszystkie etapy przeszly." }
$lines.Insert(1, $verdict)
$lines.Insert(2, "")

if ($env:GITHUB_STEP_SUMMARY) {
    $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
} else {
    $lines -join "`n" | Write-Host
}
if ($anyFailure -or -not $anyRan) { exit 1 }
