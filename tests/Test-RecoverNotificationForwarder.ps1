<#
.SYNOPSIS
    Isolated tests for NotificationForwarder Emergency Recovery mechanism.
.DESCRIPTION
    Validates:
    1. Both services healthy: no restart, zero disruption.
    2. Forwarder stopped: start triggered via existing scheduled task and verified.
    3. Watchdog disabled: reported clearly, no silent modification.
    4. Required files missing: reports exact missing files and aborts.
    5. Task start fails: reports failure clearly without unhandled exceptions.
    6. Forwarder still absent after startup wait: reports failure.
    7. Repeated recovery execution: no duplicate forwarder instances.
    8. Launcher handles paths containing spaces properly.

    SAFETY: Does not stop, restart, or modify real production tasks.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$testResults = @()

function Assert-Test {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Details = ""
    )

    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:testResults += @{ Name = $Name; Status = "PASS"; Details = $Details }
    } else {
        Write-Host "  [FAIL] $Name - $Details" -ForegroundColor Red
        $script:testResults += @{ Name = $Name; Status = "FAIL"; Details = $Details }
    }
}

$scriptDir = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
$scriptDir = (Resolve-Path $scriptDir).Path
$recoveryScript = Join-Path $scriptDir "Recover-NotificationForwarder.ps1"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Running Emergency Recovery Script Test Suite" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# ---------------------------------------------------------
# Test 1: Both services healthy -> no restart
# ---------------------------------------------------------
Write-Host "`nTest 1: Both services healthy -> no restart" -ForegroundColor White
$prodProcBefore = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -match '(?i)(?:^|[\s"''\\])NotificationForwarder\.ps1(?:[\s"'']|$)' -and
    $_.CommandLine -notlike "*Recover-NotificationForwarder*" -and
    $_.CommandLine -notlike "*Test-NotificationForwarder*" -and
    $_.CommandLine -notlike "*Test-RecoverNotificationForwarder*"
})

$healthyRes = & $recoveryScript -NonInteractive -PassThru

Assert-Test -Name "Healthy status reported when service is running" -Condition ($healthyRes.Status -eq "Healthy") -Details "Status=$($healthyRes.Status)"
Assert-Test -Name "No action taken when service is healthy" -Condition ($healthyRes.ActionTaken -eq "None") -Details "ActionTaken=$($healthyRes.ActionTaken)"

$prodProcAfter = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -match '(?i)(?:^|[\s"''\\])NotificationForwarder\.ps1(?:[\s"'']|$)' -and
    $_.CommandLine -notlike "*Recover-NotificationForwarder*" -and
    $_.CommandLine -notlike "*Test-NotificationForwarder*" -and
    $_.CommandLine -notlike "*Test-RecoverNotificationForwarder*"
})

Assert-Test -Name "Production forwarder process preserved" -Condition ($prodProcBefore.Count -eq $prodProcAfter.Count -and $prodProcBefore[0].ProcessId -eq $prodProcAfter[0].ProcessId) -Details "PID before=$($prodProcBefore[0].ProcessId), after=$($prodProcAfter[0].ProcessId)"

# ---------------------------------------------------------
# Test 2: Forwarder stopped -> start through existing task
# ---------------------------------------------------------
Write-Host "`nTest 2: Forwarder stopped -> start through existing task (Isolated dummy task)" -ForegroundColor White
$dummyFwdTask = "Test-NotificationForwarder-DummyFwd"
$dummyPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$dummySettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

# Create isolated test directory with all required files
$isolatedDir = Join-Path $env:TEMP ("RecoveryTest_Sandbox_" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $isolatedDir -Force | Out-Null
$requiredFiles = @(
    "NotificationForwarder.ps1",
    "NotificationReader.ps1",
    "NotificationFilter.ps1",
    "NotificationSender.ps1",
    "Config.ps1",
    "config.json",
    "Watchdog.ps1",
    "Run-WatchdogHidden.vbs"
)
foreach ($f in $requiredFiles) {
    Set-Content -Path (Join-Path $isolatedDir $f) -Value "# mock $f" -Encoding UTF8
}

# The mock forwarder sleeps so it can be verified as running during recovery check
$mockScript = Join-Path $isolatedDir "NotificationForwarder.ps1"
Set-Content -Path $mockScript -Value "Start-Sleep -Seconds 10" -Encoding UTF8

$dummyFwdAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$mockScript`""
$null = Register-ScheduledTask -TaskName $dummyFwdTask -Action $dummyFwdAction -Principal $dummyPrincipal -Settings $dummySettings -Force

$startRes = & $recoveryScript -ProjectDir $isolatedDir -ForwarderTaskName $dummyFwdTask -StartupWaitSeconds 2 -NonInteractive -PassThru
Assert-Test -Name "Recovery status is Recovered" -Condition ($startRes.Status -eq "Recovered") -Details "Status=$($startRes.Status)"
Assert-Test -Name "Recovery triggered Start-ScheduledTask action" -Condition ($startRes.ActionTaken -eq "Start-ScheduledTask") -Details "ActionTaken=$($startRes.ActionTaken)"
Assert-Test -Name "Active process detected after task start" -Condition ($startRes.ProcessCount -ge 1 -and $startRes.ProcessId -gt 0) -Details "PID=$($startRes.ProcessId)"

# Terminate mock sleep process if still alive
if ($startRes.ProcessId -gt 0) {
    Stop-Process -Id $startRes.ProcessId -Force -ErrorAction SilentlyContinue
}

# Cleanup Test 2
Unregister-ScheduledTask -TaskName $dummyFwdTask -Confirm:$false -ErrorAction SilentlyContinue

# ---------------------------------------------------------
# Test 3: Watchdog disabled -> report state clearly, no silent enable
# ---------------------------------------------------------
Write-Host "`nTest 3: Watchdog disabled -> report state clearly, no silent enable" -ForegroundColor White
$dummyWdTask = "Test-NotificationForwarder-DummyWd"
$dummyWdAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -Command exit 0"
$null = Register-ScheduledTask -TaskName $dummyWdTask -Action $dummyWdAction -Principal $dummyPrincipal -Settings $dummySettings -Force
Disable-ScheduledTask -TaskName $dummyWdTask -ErrorAction SilentlyContinue | Out-Null

$wdRes = & $recoveryScript -ProjectDir $scriptDir -WatchdogTaskName $dummyWdTask -NonInteractive -PassThru

Assert-Test -Name "Watchdog reported as Disabled" -Condition ($wdRes.WatchdogState -eq "Disabled") -Details "WatchdogState=$($wdRes.WatchdogState)"
Assert-Test -Name "Watchdog not modified without user consent" -Condition ($wdRes.WatchdogAction -eq "None") -Details "WatchdogAction=$($wdRes.WatchdogAction)"

$wdTaskCheck = Get-ScheduledTask -TaskName $dummyWdTask -ErrorAction SilentlyContinue
Assert-Test -Name "Watchdog task remains Disabled in Task Scheduler" -Condition ($wdTaskCheck.State -eq 'Disabled') -Details "State=$($wdTaskCheck.State)"

# Test 3b: Explicit recovery option with -EnableWatchdogIfDisabled
$wdEnableRes = & $recoveryScript -ProjectDir $scriptDir -WatchdogTaskName $dummyWdTask -EnableWatchdogIfDisabled -NonInteractive -PassThru
Assert-Test -Name "Watchdog enabled when explicitly requested" -Condition ($wdEnableRes.WatchdogAction -eq "Enabled") -Details "WatchdogAction=$($wdEnableRes.WatchdogAction)"
$wdTaskCheckAfter = Get-ScheduledTask -TaskName $dummyWdTask -ErrorAction SilentlyContinue
Assert-Test -Name "Watchdog task is now Ready in Task Scheduler" -Condition ($wdTaskCheckAfter.State -eq 'Ready') -Details "State=$($wdTaskCheckAfter.State)"

# Cleanup Test 3
Unregister-ScheduledTask -TaskName $dummyWdTask -Confirm:$false -ErrorAction SilentlyContinue

# ---------------------------------------------------------
# Test 4: Required files missing -> report exact missing file
# ---------------------------------------------------------
Write-Host "`nTest 4: Required files missing -> report exact missing file" -ForegroundColor White
$missingDir = Join-Path $env:TEMP ("RecoveryTest_Missing_" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $missingDir -Force | Out-Null
Set-Content -Path (Join-Path $missingDir "NotificationForwarder.ps1") -Value "# mock"
# Leave out NotificationFilter.ps1 and Run-WatchdogHidden.vbs

$missingRes = & $recoveryScript -ProjectDir $missingDir -NonInteractive -PassThru
Assert-Test -Name "Missing files detected and aborted" -Condition ($missingRes.Status -eq "MissingFiles" -and $missingRes.ActionTaken -eq "Aborted") -Details "Status=$($missingRes.Status)"
Assert-Test -Name "Exact missing files identified" -Condition ($missingRes.MissingFiles -contains "NotificationFilter.ps1" -and $missingRes.MissingFiles -contains "Run-WatchdogHidden.vbs") -Details "Missing: $($missingRes.MissingFiles -join ', ')"

Remove-Item -Path $missingDir -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------
# Test 5: Task start fails -> report failure clearly
# ---------------------------------------------------------
Write-Host "`nTest 5: Task start fails -> report failure clearly" -ForegroundColor White
$nonExistentTask = "NotificationForwarder-NonExistentTask99999"
$failRes = & $recoveryScript -ProjectDir $isolatedDir -ForwarderTaskName $nonExistentTask -NonInteractive -PassThru

Assert-Test -Name "Non-registered task detected" -Condition ($failRes.Status -eq "NotRegistered") -Details "Status=$($failRes.Status)"
Assert-Test -Name "Task failure handled gracefully without exception" -Condition ($failRes.ActionTaken -eq "Failed") -Details "ActionTaken=$($failRes.ActionTaken)"

# ---------------------------------------------------------
# Test 6: Forwarder still absent after startup wait -> report failure
# ---------------------------------------------------------
Write-Host "`nTest 6: Forwarder still absent after startup wait -> report failure" -ForegroundColor White
$shortLivedTask = "Test-NotificationForwarder-ShortLived"
$shortLivedAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -Command exit 0"
$null = Register-ScheduledTask -TaskName $shortLivedTask -Action $shortLivedAction -Principal $dummyPrincipal -Settings $dummySettings -Force

$absentRes = & $recoveryScript -ProjectDir $isolatedDir -ForwarderTaskName $shortLivedTask -StartupWaitSeconds 1 -NonInteractive -PassThru
Assert-Test -Name "Startup failure reported when process is absent" -Condition ($absentRes.Status -eq "StartupFailed") -Details "Status=$($absentRes.Status)"
Assert-Test -Name "Error details explain absent process" -Condition ($absentRes.Error -match "No process detected") -Details "Error=$($absentRes.Error)"

Unregister-ScheduledTask -TaskName $shortLivedTask -Confirm:$false -ErrorAction SilentlyContinue

# ---------------------------------------------------------
# Test 7: Repeated recovery execution -> no duplicate forwarder
# ---------------------------------------------------------
Write-Host "`nTest 7: Repeated recovery execution -> no duplicate forwarder" -ForegroundColor White
$firstRun = & $recoveryScript -NonInteractive -PassThru
$secondRun = & $recoveryScript -NonInteractive -PassThru

Assert-Test -Name "First run reports Healthy" -Condition ($firstRun.Status -eq "Healthy") -Details "Status=$($firstRun.Status)"
Assert-Test -Name "Second run reports Healthy" -Condition ($secondRun.Status -eq "Healthy") -Details "Status=$($secondRun.Status)"
Assert-Test -Name "Process ID is identical across runs" -Condition ($firstRun.ProcessId -eq $secondRun.ProcessId) -Details "PID 1=$($firstRun.ProcessId), PID 2=$($secondRun.ProcessId)"
Assert-Test -Name "No additional forwarder process created" -Condition ($firstRun.ProcessCount -eq 1 -and $secondRun.ProcessCount -eq 1) -Details "Count 1=$($firstRun.ProcessCount), Count 2=$($secondRun.ProcessCount)"

# Cleanup isolatedDir
Remove-Item -Path $isolatedDir -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------
# Test 8: Launcher paths containing spaces
# ---------------------------------------------------------
Write-Host "`nTest 8: Launcher paths containing spaces" -ForegroundColor White
$spaceDir = Join-Path $env:TEMP ("Recovery Test Space Dir " + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $spaceDir -Force | Out-Null

$spaceLauncher = Join-Path $spaceDir "Recover NotificationForwarder.cmd"
$spaceScript = Join-Path $spaceDir "Recover-NotificationForwarder.ps1"
Copy-Item $recoveryScript $spaceScript -Force

# Copy all required files into spaceDir so it represents a complete installation
foreach ($f in $requiredFiles) {
    if (-not (Test-Path (Join-Path $spaceDir $f))) {
        Set-Content -Path (Join-Path $spaceDir $f) -Value "# mock $f" -Encoding UTF8
    }
}

# Test invoking cmd launcher
$spaceCmdContent = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Recover-NotificationForwarder.ps1" -ProjectDir "$scriptDir" -NonInteractive
exit /b %ERRORLEVEL%
"@
[System.IO.File]::WriteAllText($spaceLauncher, $spaceCmdContent, [System.Text.Encoding]::ASCII)

$pInfo = New-Object System.Diagnostics.ProcessStartInfo
$pInfo.FileName = "cmd.exe"
$pInfo.Arguments = "/c `"$spaceLauncher`""
$pInfo.UseShellExecute = $false
$pInfo.RedirectStandardOutput = $true
$pInfo.RedirectStandardError = $true
$pInfo.CreateNoWindow = $true

$proc = [System.Diagnostics.Process]::Start($pInfo)
$stdout = $proc.StandardOutput.ReadToEnd()
$stderr = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()

Assert-Test -Name "Launcher succeeds with spaces in path" -Condition ($proc.ExitCode -eq 0) -Details "ExitCode=$($proc.ExitCode)"
Assert-Test -Name "Launcher stdout contains Diagnostic & Recovery banner" -Condition ($stdout -match "NotificationForwarder - Emergency Diagnostic & Recovery") -Details "Banner found in output"

Remove-Item -Path $spaceDir -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------
# Summary
# ---------------------------------------------------------
Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " Test Execution Summary" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
$passed = ($testResults | Where-Object { $_.Status -eq "PASS" }).Count
$failed = ($testResults | Where-Object { $_.Status -eq "FAIL" }).Count
Write-Host "  Total Tests: $($testResults.Count)" -ForegroundColor White
Write-Host "  Passed:      $passed" -ForegroundColor Green
Write-Host "  Failed:      $failed" -ForegroundColor $(if ($failed -gt 0) { [ConsoleColor]::Red } else { [ConsoleColor]::Green })

if ($failed -gt 0) {
    exit 1
} else {
    exit 0
}
