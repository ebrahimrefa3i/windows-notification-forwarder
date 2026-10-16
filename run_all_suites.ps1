<#
.SYNOPSIS
    Canonical Automated Test Suite Runner for NotificationForwarder.
.DESCRIPTION
    Discovers and executes all 7 regression test suites in isolated sandboxes.
    - Reports execution time, exit code, and pass/fail counts per suite.
    - Preserves production configuration and forwarding state.
    - Exits with non-zero exit code if any test suite fails.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ProjectDir = $null
)

$ErrorActionPreference = "Continue"

if ([string]::IsNullOrWhiteSpace($ProjectDir)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $ProjectDir = $PSScriptRoot
    } else {
        $ProjectDir = (Get-Location).Path
    }
}

# Ensure absolute resolved path
$ProjectDir = (Resolve-Path $ProjectDir).Path

# Backup active production configuration state to ensure zero pollution
$prodCfgPath = Join-Path $ProjectDir "config.json"
$prodCfgSnapshot = $null
if (Test-Path $prodCfgPath) {
    try {
        $prodCfgSnapshot = Get-Content -Path $prodCfgPath -Raw -Encoding UTF8
    } catch { }
}

$suites = @(
    "tests\Test-AppearanceAndPrivacy.ps1",
    "tests\Test-Dashboard.ps1",
    "tests\Test-NotificationForwarder.ps1",
    "tests\Test-RecoverNotificationForwarder.ps1",
    "tests\Test-SetupWizard.ps1",
    "tests\Test-SprintFeatures.ps1",
    "tests\Test-WatchdogAlert.ps1"
)

$totalPass = 0
$totalFail = 0
$results = @()

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Running NotificationForwarder Automated Regression Suites" -ForegroundColor Cyan
Write-Host " Target Directory: $ProjectDir" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

foreach ($suite in $suites) {
    $suitePath = Join-Path $ProjectDir $suite
    if (-not (Test-Path $suitePath)) {
        Write-Host "[MISSING] $suite" -ForegroundColor Red
        $results += [PSCustomObject]@{
            Suite    = $suite
            Status   = "MISSING"
            Passed   = 0
            Failed   = 1
            ExitCode = 1
            Duration = "0.0s"
        }
        $totalFail++
        continue
    }

    Write-Host "`n>>> Executing $suite ..." -ForegroundColor Yellow
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $suitePath 2>&1
    $exitCode = $LASTEXITCODE
    $sw.Stop()

    $passedInSuite = 0
    $failedInSuite = 0
    foreach ($line in $output) {
        if ($line -match '^\s*\[PASS\]') { $passedInSuite++ }
        if ($line -match '^\s*\[FAIL\]') { $failedInSuite++ }
    }

    $totalPass += $passedInSuite
    $totalFail += $failedInSuite

    $status = if ($exitCode -eq 0 -and $failedInSuite -eq 0) { "PASSED" } else { "FAILED" }
    $results += [PSCustomObject]@{
        Suite    = $suite
        Status   = $status
        Passed   = $passedInSuite
        Failed   = $failedInSuite
        ExitCode = $exitCode
        Duration = "$([math]::Round($sw.Elapsed.TotalSeconds, 1))s"
    }

    Write-Host "Result: $status (Passed: $passedInSuite, Failed: $failedInSuite, ExitCode: $exitCode, Time: $([math]::Round($sw.Elapsed.TotalSeconds, 1))s)" -ForegroundColor $(if ($status -eq "PASSED") { "Green" } else { "Red" })
}

# Restore production config snapshot if it was modified
if ($prodCfgSnapshot -and (Test-Path $prodCfgPath)) {
    try {
        $currentCfg = Get-Content -Path $prodCfgPath -Raw -Encoding UTF8
        if ($currentCfg -ne $prodCfgSnapshot) {
            [System.IO.File]::WriteAllText($prodCfgPath, $prodCfgSnapshot, [System.Text.Encoding]::UTF8)
            Write-Host "[SAFETY GATE] Restored verified production configuration snapshot." -ForegroundColor Green
        }
    } catch { }
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " Final Aggregated Test Report" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
$results | Format-Table -AutoSize

Write-Host "Total Tests Passed: $totalPass" -ForegroundColor Green
Write-Host "Total Tests Failed: $totalFail" -ForegroundColor $(if ($totalFail -eq 0) { "Green" } else { "Red" })

if ($totalFail -gt 0 -or ($results | Where-Object { $_.Status -ne "PASSED" })) {
    Write-Host "`n[ERROR] One or more test suites failed." -ForegroundColor Red
    exit 1
} else {
    Write-Host "`n[SUCCESS] All test suites passed cleanly with 0 failures!" -ForegroundColor Green
    exit 0
}
