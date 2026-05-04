# RUN-TESTS.ps1 - runs all tests and writes RESULTS.md
# Usage: powershell -ExecutionPolicy Bypass -File .\tests\RUN-TESTS.ps1

$ErrorActionPreference = 'Continue'
$here  = $PSScriptRoot
$outMd = Join-Path $here 'RESULTS.md'

$totalPassed = 0
$totalFailed = 0
$mdSections  = [System.Collections.Generic.List[string]]::new()

function Format-MdTable {
    param($Results)
    $rows = [System.Collections.Generic.List[string]]::new()
    $rows.Add('| Status | Test |')
    $rows.Add('|--------|------|')
    foreach ($r in $Results) {
        if ($r.ok) {
            $rows.Add("| PASS | $($r.name) |")
        } else {
            $err = ($r.error -replace '\r?\n', ' ') -replace '\|', '/'
            $rows.Add("| FAIL | $($r.name) -- $err |")
        }
    }
    return $rows -join [System.Environment]::NewLine
}

# --- PowerShell tests ---
Write-Host '[PS] Running Parsers.Tests.ps1...' -ForegroundColor Cyan
$psResult = & "$here\ps\Parsers.Tests.ps1"

$totalPassed += [int]$psResult.passed
$totalFailed += [int]$psResult.failed

$psStatus = if ($psResult.failed -eq 0) { 'All passed' } else { "$($psResult.failed) failed" }
$psTable  = Format-MdTable -Results $psResult.results

$sec  = "## PowerShell - Parsing Logic" + [System.Environment]::NewLine + [System.Environment]::NewLine
$sec += "**Result:** $psStatus | Passed: $($psResult.passed) | Failed: $($psResult.failed)" + [System.Environment]::NewLine + [System.Environment]::NewLine
$sec += $psTable
$mdSections.Add($sec)

$c = if ($psResult.failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "  Passed: $($psResult.passed)  Failed: $($psResult.failed)" -ForegroundColor $c

# --- JavaScript tests ---
Write-Host '[JS] Running helpers.test.js...' -ForegroundColor Cyan
$nodeCmd  = Get-Command node -ErrorAction SilentlyContinue
$jsResult = $null

if ($nodeCmd) {
    $jsDir    = Join-Path $here 'js'
    $wrapPath = Join-Path $env:TEMP 'cf_wrap.js'
    $testFile = Join-Path $jsDir 'helpers.test.js'
    $wrapCode = "const t = require('" + $testFile.Replace('\', '/') + "'); process.stdout.write(JSON.stringify({passed:t.passed,failed:t.failed,results:t.results}));"
    [System.IO.File]::WriteAllText($wrapPath, $wrapCode, [System.Text.Encoding]::UTF8)

    $jsJson = node $wrapPath 2>$null
    Remove-Item $wrapPath -ErrorAction SilentlyContinue

    if ($jsJson) {
        try {
            $jsResult     = $jsJson | ConvertFrom-Json
            $totalPassed += [int]$jsResult.passed
            $totalFailed += [int]$jsResult.failed

            $jsStatus = if ($jsResult.failed -eq 0) { 'All passed' } else { "$($jsResult.failed) failed" }
            $jsTable  = Format-MdTable -Results $jsResult.results

            $sec  = "## JavaScript - Helper Functions" + [System.Environment]::NewLine + [System.Environment]::NewLine
            $sec += "**Result:** $jsStatus | Passed: $($jsResult.passed) | Failed: $($jsResult.failed)" + [System.Environment]::NewLine + [System.Environment]::NewLine
            $sec += $jsTable
            $mdSections.Add($sec)

            $c = if ($jsResult.failed -eq 0) { 'Green' } else { 'Red' }
            Write-Host "  Passed: $($jsResult.passed)  Failed: $($jsResult.failed)" -ForegroundColor $c
        } catch {
            $mdSections.Add('## JavaScript' + [System.Environment]::NewLine + [System.Environment]::NewLine + '> WARNING: Could not parse Node.js output.')
            Write-Host '  WARNING: Could not parse JS output' -ForegroundColor Yellow
        }
    } else {
        $mdSections.Add('## JavaScript' + [System.Environment]::NewLine + [System.Environment]::NewLine + '> WARNING: Node.js returned no output.')
        Write-Host '  WARNING: No output from node' -ForegroundColor Yellow
    }
} else {
    $mdSections.Add('## JavaScript' + [System.Environment]::NewLine + [System.Environment]::NewLine + '> SKIPPED: Node.js not found.')
    Write-Host '  SKIPPED: Node.js not found' -ForegroundColor Yellow
}

# --- Build RESULTS.md ---
$overallStatus = if ($totalFailed -eq 0) { 'ALL PASSED' } else { "FAILED ($totalFailed errors)" }
$dateStr       = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$nl            = [System.Environment]::NewLine

$jsPassedStr = if ($null -ne $jsResult) { [string]$jsResult.passed } else { '--' }
$jsFailedStr = if ($null -ne $jsResult) { [string]$jsResult.failed } else { '--' }

$md  = "# CYBERFORTRESS // TEST RESULTS$nl$nl"
$md += "**Date:** $dateStr$nl$nl"
$md += "## Summary - $overallStatus$nl$nl"
$md += "| Suite | Passed | Failed |$nl"
$md += "|-------|--------|--------|$nl"
$md += "| PowerShell parsers | $($psResult.passed) | $($psResult.failed) |$nl"
$md += "| JavaScript helpers | $jsPassedStr | $jsFailedStr |$nl"
$md += "| **Total** | **$totalPassed** | **$totalFailed** |$nl$nl"
$md += $mdSections -join ($nl + $nl)

[System.IO.File]::WriteAllText($outMd, $md, [System.Text.Encoding]::UTF8)

Write-Host ''
Write-Host '=====================================' -ForegroundColor Magenta
$c = if ($totalFailed -eq 0) { 'Green' } else { 'Red' }
Write-Host "  TOTAL  Passed: $totalPassed  Failed: $totalFailed" -ForegroundColor $c
Write-Host "  Results: $outMd" -ForegroundColor Cyan
Write-Host '=====================================' -ForegroundColor Magenta
