<#
.SYNOPSIS
    Isolated tests for NotificationForwarder Service-Failure Alerting mechanism.
.DESCRIPTION
    Validates:
    1. Healthy forwarder: No recovery needed, no alert sent, alert state cleared if present.
    2. Successful recovery: Normal restart verified, NO alert sent.
    3. Failed recovery: Process absent after verification timeout -> Alert dispatched to ntfy.
    4. Duplicate-alert prevention: Second failed run suppresses duplicate alert for same incident.
    5. Alert state reset: Alert state cleared once forwarder successfully recovers.
    6. ntfy unavailable: Handles network failures gracefully, logs locally, prevents alert loops.
    7. Secret scrubbing: Confirms alert logs scrub topics, tokens, and raw URLs.

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
$watchdogScript = Join-Path $scriptDir "Watchdog.ps1"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Running Watchdog Service-Failure Alert Test Suite" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$testPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$testSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

# ---------------------------------------------------------
# Test 1: Healthy forwarder -> no restart, no alert
# ---------------------------------------------------------
Write-Host "`nTest 1: Healthy forwarder -> no restart, no alert" -ForegroundColor White
$healthyLog = Join-Path $env:TEMP ("watchdog_healthy_" + [System.Guid]::NewGuid().ToString("N") + ".log")
$healthyAlertState = Join-Path $env:TEMP ("alert_state_h_" + [System.Guid]::NewGuid().ToString("N"))
Set-Content -Path $healthyAlertState -Value "stale incident" -Encoding UTF8

$healthyRes = & $watchdogScript -LogPath $healthyLog -AlertStatePath $healthyAlertState -PassThru

Assert-Test -Name "Status is Running for healthy service" -Condition ($healthyRes.Status -eq "Running") -Details "Status=$($healthyRes.Status)"
Assert-Test -Name "ActionTaken is None for healthy service" -Condition ($healthyRes.ActionTaken -eq "None") -Details "ActionTaken=$($healthyRes.ActionTaken)"
Assert-Test -Name "Stale alert state file cleared on healthy check" -Condition (-not (Test-Path $healthyAlertState)) -Details "AlertStateCleared=$(-not (Test-Path $healthyAlertState))"

if (Test-Path $healthyLog) { Remove-Item $healthyLog -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------
# Test 2: Successful recovery -> restart succeeds, NO alert sent
# ---------------------------------------------------------
Write-Host "`nTest 2: Successful recovery -> restart succeeds, NO alert sent" -ForegroundColor White
$sandboxDir2 = Join-Path $env:TEMP ("WatchdogAlert_Sandbox2_" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $sandboxDir2 -Force | Out-Null
$mockFwdScript2 = Join-Path $sandboxDir2 "NotificationForwarder.ps1"
Set-Content -Path $mockFwdScript2 -Value "Start-Sleep -Seconds 15" -Encoding UTF8

$dummySuccessTask = "Test-WatchdogAlert-SuccessTask"
$dummySuccessAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$mockFwdScript2`""
$null = Register-ScheduledTask -TaskName $dummySuccessTask -Action $dummySuccessAction -Principal $testPrincipal -Settings $testSettings -Force

$testLog2 = Join-Path $sandboxDir2 "watchdog_test2.log"
$alertState2 = Join-Path $sandboxDir2 ".alert_state"

$capturedAlerts2 = [System.Collections.ArrayList]::new()
$mockHttp2 = {
    param($Url, $Headers, $Body, $Attempt)
    $capturedAlerts2.Add(@{ Url = $Url; Headers = $Headers; Body = $Body }) | Out-Null
}

$successRes = & $watchdogScript `
    -ForwarderTaskName $dummySuccessTask `
    -LogPath $testLog2 `
    -AlertStatePath $alertState2 `
    -RecoveryVerifySeconds 2 `
    -CustomHttpHandler $mockHttp2 `
    -ForceRestart `
    -PassThru

Assert-Test -Name "Recovery status is Succeeded" -Condition ($successRes.RecoveryStatus -eq "Succeeded") -Details "RecoveryStatus=$($successRes.RecoveryStatus)"
Assert-Test -Name "RecoverySuccess flag is True" -Condition ($successRes.RecoverySuccess -eq $true) -Details "RecoverySuccess=$($successRes.RecoverySuccess)"
Assert-Test -Name "NO alert sent when recovery succeeds" -Condition ($successRes.AlertSent -eq $false -and $capturedAlerts2.Count -eq 0) -Details "AlertSent=$($successRes.AlertSent), CapturedCount=$($capturedAlerts2.Count)"
Assert-Test -Name "No alert state file created on successful recovery" -Condition (-not (Test-Path $alertState2)) -Details "AlertStateExists=$(Test-Path $alertState2)"

# Cleanup Test 2 process and task
if ($successRes.ProcessId -gt 0) {
    Stop-Process -Id $successRes.ProcessId -Force -ErrorAction SilentlyContinue
}
Unregister-ScheduledTask -TaskName $dummySuccessTask -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -Path $sandboxDir2 -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------
# Test 3: Failed recovery -> Alert dispatched to ntfy
# ---------------------------------------------------------
Write-Host "`nTest 3: Failed recovery -> Alert dispatched to ntfy" -ForegroundColor White
$sandboxDir3 = Join-Path $env:TEMP ("WatchdogAlert_Sandbox3_" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $sandboxDir3 -Force | Out-Null

$dummyFailTask = "Test-WatchdogAlert-FailTask"
$dummyFailAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -Command exit 0"
$null = Register-ScheduledTask -TaskName $dummyFailTask -Action $dummyFailAction -Principal $testPrincipal -Settings $testSettings -Force

$testLog3 = Join-Path $sandboxDir3 "watchdog_test3.log"
$alertState3 = Join-Path $sandboxDir3 ".alert_state"

$capturedAlerts3 = [System.Collections.ArrayList]::new()
$mockHttp3 = {
    param($Url, $Headers, $Body, $Attempt)
    $capturedAlerts3.Add(@{ Url = $Url; Headers = $Headers; Body = $Body }) | Out-Null
}

$failRes = & $watchdogScript `
    -ForwarderTaskName $dummyFailTask `
    -LogPath $testLog3 `
    -AlertStatePath $alertState3 `
    -RecoveryVerifySeconds 1 `
    -CustomHttpHandler $mockHttp3 `
    -ForceRestart `
    -PassThru

Assert-Test -Name "Recovery status is Failed" -Condition ($failRes.RecoveryStatus -eq "Failed") -Details "RecoveryStatus=$($failRes.RecoveryStatus)"
Assert-Test -Name "RecoverySuccess flag is False" -Condition ($failRes.RecoverySuccess -eq $false) -Details "RecoverySuccess=$($failRes.RecoverySuccess)"
Assert-Test -Name "AlertSent flag is True" -Condition ($failRes.AlertSent -eq $true) -Details "AlertSent=$($failRes.AlertSent)"
Assert-Test -Name "Alert HTTP request was captured" -Condition ($capturedAlerts3.Count -eq 1) -Details "CapturedCount=$($capturedAlerts3.Count)"
Assert-Test -Name "Alert contains generic recovery failed message" -Condition ($capturedAlerts3[0].Body -match "NotificationForwarder needs attention\. Automatic recovery failed\.") -Details "Body=$($capturedAlerts3[0].Body)"
Assert-Test -Name "Alert header contains Service Alert title" -Condition ($capturedAlerts3[0].Headers["Title"] -match "NotificationForwarder.*Service Alert") -Details "Title=$($capturedAlerts3[0].Headers['Title'])"
Assert-Test -Name "Alert header contains Priority" -Condition ($capturedAlerts3[0].Headers["Priority"] -in @("3", "4", "urgent", "high", "default")) -Details "Priority=$($capturedAlerts3[0].Headers['Priority'])"
Assert-Test -Name "Alert state file created on disk" -Condition (Test-Path $alertState3) -Details "AlertStateExists=$(Test-Path $alertState3)"

# ---------------------------------------------------------
# Test 4: Duplicate-alert prevention -> second run suppresses alert
# ---------------------------------------------------------
Write-Host "`nTest 4: Duplicate-alert prevention -> second run suppresses alert" -ForegroundColor White
$dupRes = & $watchdogScript `
    -ForwarderTaskName $dummyFailTask `
    -LogPath $testLog3 `
    -AlertStatePath $alertState3 `
    -RecoveryVerifySeconds 1 `
    -CustomHttpHandler $mockHttp3 `
    -ForceRestart `
    -PassThru

Assert-Test -Name "Duplicate run reports AlertSent = False" -Condition ($dupRes.AlertSent -eq $false) -Details "AlertSent=$($dupRes.AlertSent)"
Assert-Test -Name "Duplicate run reports AlertSkipped = True" -Condition ($dupRes.AlertSkipped -eq $true) -Details "AlertSkipped=$($dupRes.AlertSkipped)"
Assert-Test -Name "Total captured alerts remains 1 (no duplicate sent)" -Condition ($capturedAlerts3.Count -eq 1) -Details "CapturedCount=$($capturedAlerts3.Count)"

$logContent3 = if (Test-Path $testLog3) { Get-Content $testLog3 -Raw } else { "" }
Assert-Test -Name "Log confirms suppression of duplicate alert" -Condition ($logContent3 -match "Suppressing duplicate alert") -Details "Match in log"

# ---------------------------------------------------------
# Test 5: Alert state reset after forwarder recovers
# ---------------------------------------------------------
Write-Host "`nTest 5: Alert state reset after forwarder recovers" -ForegroundColor White
# Register a task that stays alive
$mockFwdScript5 = Join-Path $sandboxDir3 "NotificationForwarder.ps1"
Set-Content -Path $mockFwdScript5 -Value "Start-Sleep -Seconds 15" -Encoding UTF8
$dummyRecoverAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$mockFwdScript5`""
$null = Register-ScheduledTask -TaskName $dummyFailTask -Action $dummyRecoverAction -Principal $testPrincipal -Settings $testSettings -Force

$recoverRes = & $watchdogScript `
    -ForwarderTaskName $dummyFailTask `
    -LogPath $testLog3 `
    -AlertStatePath $alertState3 `
    -RecoveryVerifySeconds 2 `
    -CustomHttpHandler $mockHttp3 `
    -ForceRestart `
    -PassThru

Assert-Test -Name "Recovery status is Succeeded upon process alive" -Condition ($recoverRes.RecoveryStatus -eq "Succeeded") -Details "RecoveryStatus=$($recoverRes.RecoveryStatus)"
Assert-Test -Name "Alert state file cleared after recovery" -Condition (-not (Test-Path $alertState3)) -Details "AlertStateExists=$(Test-Path $alertState3)"

if ($recoverRes.ProcessId -gt 0) {
    Stop-Process -Id $recoverRes.ProcessId -Force -ErrorAction SilentlyContinue
}
Unregister-ScheduledTask -TaskName $dummyFailTask -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -Path $sandboxDir3 -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------
# Test 6: ntfy unavailable -> no alert loop, error logged, normal operation
# ---------------------------------------------------------
Write-Host "`nTest 6: ntfy unavailable -> no alert loop, error logged, normal operation" -ForegroundColor White
$sandboxDir6 = Join-Path $env:TEMP ("WatchdogAlert_Sandbox6_" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $sandboxDir6 -Force | Out-Null

$dummyNetFailTask = "Test-WatchdogAlert-NetFailTask"
$dummyNetFailAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -Command exit 0"
$null = Register-ScheduledTask -TaskName $dummyNetFailTask -Action $dummyNetFailAction -Principal $testPrincipal -Settings $testSettings -Force

$testLog6 = Join-Path $sandboxDir6 "watchdog_test6.log"
$alertState6 = Join-Path $sandboxDir6 ".alert_state"

$mockFailingHttp = {
    param($Url, $Headers, $Body, $Attempt)
    throw [System.Net.WebException]::new("Unable to connect to the remote server. Network down.")
}

$netFailRes = $null
$threwException = $false
try {
    $netFailRes = & $watchdogScript `
        -ForwarderTaskName $dummyNetFailTask `
        -LogPath $testLog6 `
        -AlertStatePath $alertState6 `
        -RecoveryVerifySeconds 1 `
        -CustomHttpHandler $mockFailingHttp `
        -ForceRestart `
        -PassThru
} catch {
    $threwException = $true
}

Assert-Test -Name "Watchdog did not throw unhandled exception when ntfy failed" -Condition ($threwException -eq $false) -Details "Threw=$threwException"
Assert-Test -Name "AlertSent is False on network failure" -Condition ($netFailRes.AlertSent -eq $false) -Details "AlertSent=$($netFailRes.AlertSent)"
Assert-Test -Name "AlertError captured network failure" -Condition ($netFailRes.AlertError -match "Unable to connect") -Details "AlertError=$($netFailRes.AlertError)"
Assert-Test -Name "Alert state persisted to prevent repeated retry loops" -Condition (Test-Path $alertState6) -Details "AlertStateExists=$(Test-Path $alertState6)"

# Second run with network down verifies no loop / no duplicate attempts
$netFailDupRes = & $watchdogScript `
    -ForwarderTaskName $dummyNetFailTask `
    -LogPath $testLog6 `
    -AlertStatePath $alertState6 `
    -RecoveryVerifySeconds 1 `
    -CustomHttpHandler $mockFailingHttp `
    -ForceRestart `
    -PassThru

Assert-Test -Name "Subsequent run suppresses duplicate alert attempt during network outage" -Condition ($netFailDupRes.AlertSkipped -eq $true) -Details "AlertSkipped=$($netFailDupRes.AlertSkipped)"

# ---------------------------------------------------------
# Test 7: Secret scrubbing in failure alert logs
# ---------------------------------------------------------
Write-Host "`nTest 7: Secret scrubbing in failure alert logs" -ForegroundColor White
$logContent6 = if (Test-Path $testLog6) { Get-Content $testLog6 -Raw } else { "" }
Assert-Test -Name "Log records alert delivery attempt warning" -Condition ($logContent6 -match "Could not deliver failure alert to ntfy") -Details "Match in log"

$secretTopic = "my_super_secret_topic_99999"
$secretToken = "tk_secret_token_abcdef123456"
$mockConfigWithSecrets = @{
    NtfyServer            = "https://ntfy.sh"
    NtfyTopic             = $secretTopic
    NtfyToken             = $secretToken
    DryRun                = $false
    LiveForwardingEnabled = $true
}

$mockSecretHttp = {
    param($Url, $Headers, $Body, $Attempt)
    throw [System.Exception]::new("Failed connecting to $Url with token $secretToken")
}

$secretAlertLog = Join-Path $sandboxDir6 "secret_alert_test.log"
$secretAlertState = Join-Path $sandboxDir6 ".secret_alert_state"

$secretConfigFile = Join-Path $sandboxDir6 "secret_config.json"
$mockConfigWithSecrets | ConvertTo-Json | Set-Content -Path $secretConfigFile -Encoding UTF8

$null = & $watchdogScript `
    -ConfigPath $secretConfigFile `
    -ForwarderTaskName $dummyNetFailTask `
    -LogPath $secretAlertLog `
    -AlertStatePath $secretAlertState `
    -RecoveryVerifySeconds 1 `
    -CustomHttpHandler $mockSecretHttp `
    -ForceRestart `
    -PassThru

$secretLogContent = if (Test-Path $secretAlertLog) { Get-Content $secretAlertLog -Raw } else { "" }
Assert-Test -Name "Alert log contains NO raw secret topic" -Condition ($secretLogContent -notmatch [regex]::Escape($secretTopic)) -Details "Topic scrubbed"
Assert-Test -Name "Alert log contains NO raw secret token" -Condition ($secretLogContent -notmatch [regex]::Escape($secretToken)) -Details "Token scrubbed"

# Cleanup Test 6/7
Unregister-ScheduledTask -TaskName $dummyNetFailTask -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -Path $sandboxDir6 -Recurse -Force -ErrorAction SilentlyContinue

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
