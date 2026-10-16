<#
.SYNOPSIS
    Isolated Test Suite for NotificationForwarder Sprint Features.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    $scriptDir = (Get-Location).Path
}
$parentDir = Split-Path $scriptDir -Parent
if (Test-Path (Join-Path $scriptDir "Config.ps1")) {
    $projDir = $scriptDir
} elseif (-not [string]::IsNullOrWhiteSpace($parentDir) -and (Test-Path (Join-Path $parentDir "Config.ps1"))) {
    $projDir = $parentDir
} else {
    $projDir = (Get-Location).Path
}
$projDir = (Resolve-Path $projDir).Path

. (Join-Path $projDir "Config.ps1")
. (Join-Path $projDir "NotificationReader.ps1")
. (Join-Path $projDir "NotificationFilter.ps1")
. (Join-Path $projDir "NotificationSender.ps1")

$testResults = [System.Collections.ArrayList]::new()
function Assert-Test {
    param([string]$Name, [bool]$Condition, [string]$Details = "")
    $status = if ($Condition) { "PASS" } else { "FAIL" }
    $color = if ($Condition) { [ConsoleColor]::Green } else { [ConsoleColor]::Red }
    Write-Host "  [$status] $Name" -ForegroundColor $color
    if (-not $Condition -and $Details) {
        Write-Host "         Details: $Details" -ForegroundColor Yellow
    }
    $testResults.Add([PSCustomObject]@{ Name = $Name; Status = $status; Details = $Details }) | Out-Null
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Running Sprint Features Test Suite" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# ==============================================================================
# Suite 1: Privacy Modes & Safe Fallback
# ==============================================================================
Write-Host "`nTest Suite 1: Privacy Modes (TitleOnly vs TitleAndBody & Fallback)" -ForegroundColor White

$mockBinding = New-Object PSObject
$mockBinding | Add-Member -MemberType ScriptMethod -Name "GetTextElements" -Value {
    return @(
        [PSCustomObject]@{ Text = "Security Alert" },
        [PSCustomObject]@{ Text = "Suspicious login detected from IP 192.168.1.50" }
    )
}
$mockVisual = New-Object PSObject
$mockVisual | Add-Member -MemberType ScriptMethod -Name "GetBinding" -Value {
    param($kind)
    return $mockBinding
}
$mockNotificationObj = [PSCustomObject]@{
    Id           = 8001
    CreationTime = [DateTimeOffset]::Now
    AppInfo      = [PSCustomObject]@{
        AppUserModelId = "Windows.Defender.SecurityCenter"
        DisplayInfo    = [PSCustomObject]@{ DisplayName = "Windows Security" }
    }
    Notification = [PSCustomObject]@{
        Visual = $mockVisual
    }
}

# 1.1 TitleOnly Mode
$dataTitleOnly = Extract-NotificationData -UserNotification $mockNotificationObj -PrivacyMode "TitleOnly"
Assert-Test -Name "TitleOnly mode extracts correct Title" -Condition ($dataTitleOnly.Title -eq "Security Alert") -Details "Title=$($dataTitleOnly.Title)"
Assert-Test -Name "TitleOnly mode suppresses Body (empty string)" -Condition ($dataTitleOnly.Body -eq "") -Details "Body=$($dataTitleOnly.Body)"
Assert-Test -Name "TitleOnly records PrivacyModeUsed = TitleOnly" -Condition ($dataTitleOnly.PrivacyModeUsed -eq "TitleOnly")

# 1.2 TitleAndBody Mode
$dataTitleAndBody = Extract-NotificationData -UserNotification $mockNotificationObj -PrivacyMode "TitleAndBody"
Assert-Test -Name "TitleAndBody mode extracts correct Title" -Condition ($dataTitleAndBody.Title -eq "Security Alert") -Details "Title=$($dataTitleAndBody.Title)"
Assert-Test -Name "TitleAndBody mode includes Body" -Condition ($dataTitleAndBody.Body -like "*Suspicious login*") -Details "Body=$($dataTitleAndBody.Body)"
Assert-Test -Name "TitleAndBody records PrivacyModeUsed = TitleAndBody" -Condition ($dataTitleAndBody.PrivacyModeUsed -eq "TitleAndBody")

# 1.3 Safe Fallback for Invalid PrivacyMode
$dataInvalid = Extract-NotificationData -UserNotification $mockNotificationObj -PrivacyMode "InvalidBogusMode"
Assert-Test -Name "Invalid PrivacyMode safely falls back to TitleOnly" -Condition ($dataInvalid.PrivacyModeUsed -eq "TitleOnly") -Details "Mode=$($dataInvalid.PrivacyModeUsed)"
Assert-Test -Name "Invalid PrivacyMode suppresses Body on fallback" -Condition ($dataInvalid.Body -eq "") -Details "Body=$($dataInvalid.Body)"

# 1.4 Config loader validation fallback
$sandboxDir = Join-Path $env:TEMP ("SprintTest_Sandbox_" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $sandboxDir -Force | Out-Null
$testCfgPath = Join-Path $sandboxDir "config.json"

@{ PrivacyMode = "InVaLiD_Mode" } | ConvertTo-Json | Set-Content -Path $testCfgPath -Encoding UTF8
$loadedCfg = Load-AppConfig -ConfigPath $testCfgPath
Assert-Test -Name "Load-AppConfig normalizes invalid PrivacyMode to TitleOnly" -Condition ($loadedCfg.PrivacyMode -eq "TitleOnly") -Details "PrivacyMode=$($loadedCfg.PrivacyMode)"

@{ PrivacyMode = "titleandbody" } | ConvertTo-Json | Set-Content -Path $testCfgPath -Encoding UTF8
$loadedCfg2 = Load-AppConfig -ConfigPath $testCfgPath
Assert-Test -Name "Load-AppConfig accepts case-insensitive TitleAndBody" -Condition ($loadedCfg2.PrivacyMode -eq "TitleAndBody") -Details "PrivacyMode=$($loadedCfg2.PrivacyMode)"

# 1.5 Filter and Sender Payload Verification
$mockConfigTitleOnly = @{ PrivacyMode = "TitleOnly"; AppFilterMode = "Allowlist"; AllowedAppIds = @("Windows Security"); BlockedAppIds = @() }
$filteredTitleOnly = Filter-Notification -NotificationData $dataTitleOnly -Config $mockConfigTitleOnly
Assert-Test -Name "Filter enforces TitleOnly body is empty" -Condition ($filteredTitleOnly.Body -eq "")

$mockConfigBoth = @{ PrivacyMode = "TitleAndBody"; AppFilterMode = "Allowlist"; AllowedAppIds = @("Windows Security"); BlockedAppIds = @() }
$filteredBoth = Filter-Notification -NotificationData $dataTitleAndBody -Config $mockConfigBoth
Assert-Test -Name "Filter preserves body in TitleAndBody mode" -Condition ($filteredBoth.Body -like "*Suspicious login*")

# Verify Sender payload selection
$capturedPayloads = [System.Collections.ArrayList]::new()
$mockSenderHandler = {
    param($Url, $Headers, $Body, $Attempt)
    $capturedPayloads.Add(@{ Headers = $Headers; Body = $Body }) | Out-Null
}

$mockSenderCfg = @{
    NtfyServer            = "https://ntfy.sh"
    NtfyTopic             = "mock_test_topic"
    DryRun                = $false
    LiveForwardingEnabled = $true
}

$null = Send-SingleAttempt -FilteredNotification $filteredTitleOnly -Config $mockSenderCfg -AttemptNumber 1 -CustomHttpHandler $mockSenderHandler
Assert-Test -Name "Sender sends Title as payload under TitleOnly" -Condition ($capturedPayloads[0].Body -eq "Security Alert") -Details "Body=$($capturedPayloads[0].Body)"

$null = Send-SingleAttempt -FilteredNotification $filteredBoth -Config $mockSenderCfg -AttemptNumber 1 -CustomHttpHandler $mockSenderHandler
Assert-Test -Name "Sender sends Body as payload under TitleAndBody" -Condition ($capturedPayloads[1].Body -like "*Suspicious login*") -Details "Body=$($capturedPayloads[1].Body)"
Assert-Test -Name "Sender sends App: Title in header under TitleAndBody" -Condition ($capturedPayloads[1].Headers["Title"] -like "*Windows Security: Security Alert*") -Details "Title=$($capturedPayloads[1].Headers['Title'])"

# ==============================================================================
# Suite 2: Easy Application Filtering (Allowlist & Blocklist)
# ==============================================================================
Write-Host "`nTest Suite 2: Easy Application Filtering (Allowlist & Blocklist)" -ForegroundColor White

$prodAllowed = @(
    "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe",
    "Chrome",
    "Google Chrome",
    "Windows.Defender.SecurityCenter",
    "Windows Security",
    "5319275A.WhatsAppDesktop_cv1g1gvanyjgm!App",
    "WhatsApp",
    "Telegram.TelegramDesktop",
    "Telegram",
    "Google.AntigravityIDE"
)

# 2.1 Allowlist matches allowed apps
$isWhatsAppAllowed = Test-IsAppAllowed -AppDisplayName "WhatsApp" -AppFilterMode "Allowlist" -AllowedAppIds $prodAllowed
Assert-Test -Name "Allowlist allows WhatsApp" -Condition ($isWhatsAppAllowed -eq $true)

$isChromeAllowed = Test-IsAppAllowed -AppDisplayName "Google Chrome" -AppFilterMode "Allowlist" -AllowedAppIds $prodAllowed
Assert-Test -Name "Allowlist allows Google Chrome" -Condition ($isChromeAllowed -eq $true)

# 2.2 Allowlist denies unknown apps
$isGameAllowed = Test-IsAppAllowed -AppDisplayName "RandomGame.exe" -AppFilterMode "Allowlist" -AllowedAppIds $prodAllowed
Assert-Test -Name "Allowlist blocks non-whitelisted app" -Condition ($isGameAllowed -eq $false)

# 2.3 Blocklist allows non-blocked apps
$testBlocklist = @("SpamApp", "*Adware*", "AnnoyingGame")
$isNormalAllowed = Test-IsAppAllowed -AppDisplayName "WhatsApp" -AppFilterMode "Blocklist" -BlockedAppIds $testBlocklist
Assert-Test -Name "Blocklist permits normal app not on blocklist" -Condition ($isNormalAllowed -eq $true)

# 2.4 Blocklist blocks explicitly blocked apps
$isSpamBlocked = Test-IsAppAllowed -AppDisplayName "SpamApp" -AppFilterMode "Blocklist" -BlockedAppIds $testBlocklist
Assert-Test -Name "Blocklist blocks exact match" -Condition ($isSpamBlocked -eq $false)

$isAdwareBlocked = Test-IsAppAllowed -AppDisplayName "BadAdwareInstaller" -AppFilterMode "Blocklist" -BlockedAppIds $testBlocklist
Assert-Test -Name "Blocklist blocks wildcard pattern match" -Condition ($isAdwareBlocked -eq $false)

# 2.5 BlockedAppIds also blocks apps under Allowlist if listed
$isOverrideBlocked = Test-IsAppAllowed -AppDisplayName "WhatsApp" -AppFilterMode "Allowlist" -AllowedAppIds $prodAllowed -BlockedAppIds @("WhatsApp")
Assert-Test -Name "BlockedAppIds takes precedence over AllowedAppIds" -Condition ($isOverrideBlocked -eq $false)

# 2.6 Config validation safe fallback for invalid filter mode
@{ AppFilterMode = "NonExistentMode" } | ConvertTo-Json | Set-Content -Path $testCfgPath -Encoding UTF8
$loadedCfg3 = Load-AppConfig -ConfigPath $testCfgPath
Assert-Test -Name "Invalid AppFilterMode safely falls back to Allowlist" -Condition ($loadedCfg3.AppFilterMode -eq "Allowlist") -Details "Mode=$($loadedCfg3.AppFilterMode)"

# ==============================================================================
# Suite 3: Internet Connection Recovery Notification in Watchdog
# ==============================================================================
Write-Host "`nTest Suite 3: Internet Connection Recovery Notification" -ForegroundColor White

$watchdogScript = Join-Path $projDir "Watchdog.ps1"
$netStatePath = Join-Path $sandboxDir ".network_state"
$netLogPath = Join-Path $sandboxDir "watchdog_net.log"

$capturedNetAlerts = [System.Collections.ArrayList]::new()
$mockNetSender = {
    param($Url, $Headers, $Body, $Attempt)
    $capturedNetAlerts.Add(@{ Url = $Url; Headers = $Headers; Body = $Body }) | Out-Null
}

# 3.1 Brief network fluctuation (1 check fails, next succeeds) -> NO alert sent
$simOnline = $false
$mockNetChecker = { return $simOnline }

# Cycle 1: Network down
$res1 = & $watchdogScript `
    -NetworkStatePath $netStatePath `
    -LogPath $netLogPath `
    -NetworkOutageThreshold 2 `
    -CustomNetworkChecker $mockNetChecker `
    -CustomHttpHandler $mockNetSender `
    -PassThru

Assert-Test -Name "Cycle 1 (down): Network is offline" -Condition ($res1.NetworkOnline -eq $false)
Assert-Test -Name "Cycle 1 (down): No recovery alert sent" -Condition ($res1.NetworkRecoverySent -eq $false)
Assert-Test -Name "Cycle 1 (down): Consecutive failures = 1 recorded in state" -Condition ((Test-Path $netStatePath) -and ((Get-Content $netStatePath | ConvertFrom-Json).ConsecutiveFailures -eq 1))

# Cycle 2: Network recovers immediately (brief fluctuation < threshold of 2)
$simOnline = $true
$res2 = & $watchdogScript `
    -NetworkStatePath $netStatePath `
    -LogPath $netLogPath `
    -NetworkOutageThreshold 2 `
    -CustomNetworkChecker $mockNetChecker `
    -CustomHttpHandler $mockNetSender `
    -PassThru

Assert-Test -Name "Cycle 2 (brief recovered): Network is online" -Condition ($res2.NetworkOnline -eq $true)
Assert-Test -Name "Cycle 2 (brief recovered): NO recovery alert sent for brief fluctuation" -Condition ($res2.NetworkRecoverySent -eq $false)
Assert-Test -Name "Cycle 2 (brief recovered): Fluctuation state cleared from disk" -Condition (-not (Test-Path $netStatePath))
Assert-Test -Name "Cycle 2 (brief recovered): Zero alerts captured" -Condition ($capturedNetAlerts.Count -eq 0)

# 3.2 Sustained Outage -> 2 consecutive failures
$simOnline = $false
# Outage cycle 1
$null = & $watchdogScript -NetworkStatePath $netStatePath -LogPath $netLogPath -NetworkOutageThreshold 2 -CustomNetworkChecker $mockNetChecker -CustomHttpHandler $mockNetSender -PassThru
# Outage cycle 2 (reaches threshold)
$resSustained = & $watchdogScript -NetworkStatePath $netStatePath -LogPath $netLogPath -NetworkOutageThreshold 2 -CustomNetworkChecker $mockNetChecker -CustomHttpHandler $mockNetSender -PassThru

$sustainedState = Get-Content $netStatePath | ConvertFrom-Json
Assert-Test -Name "Sustained outage confirms OutageConfirmed = True" -Condition ($sustainedState.OutageConfirmed -eq $true)
Assert-Test -Name "Sustained outage records ConsecutiveFailures = 2" -Condition ($sustainedState.ConsecutiveFailures -eq 2)

# 3.3 Recovery after sustained outage -> Exactly ONE alert sent
$simOnline = $true
$resRecovered = & $watchdogScript `
    -NetworkStatePath $netStatePath `
    -LogPath $netLogPath `
    -NetworkOutageThreshold 2 `
    -CustomNetworkChecker $mockNetChecker `
    -CustomHttpHandler $mockNetSender `
    -PassThru

Assert-Test -Name "Recovery after sustained outage reports NetworkRecoverySent = True" -Condition ($resRecovered.NetworkRecoverySent -eq $true)
Assert-Test -Name "Recovery alert captured via HTTP sender" -Condition ($capturedNetAlerts.Count -eq 1)
Assert-Test -Name "Recovery alert contains exact generic message" -Condition ($capturedNetAlerts[0].Body -match "Internet connection restored\. NotificationForwarder is online\.") -Details "Body=$($capturedNetAlerts[0].Body)"
Assert-Test -Name "Recovery alert header contains Network Alert title" -Condition ($capturedNetAlerts[0].Headers["Title"] -match "Network Alert") -Details "Title=$($capturedNetAlerts[0].Headers['Title'])"
Assert-Test -Name "Network state file cleared upon successful recovery alert" -Condition (-not (Test-Path $netStatePath))

# 3.4 Duplicate Prevention -> Next run while still online does NOT send another alert
$resOnlineSubsequent = & $watchdogScript `
    -NetworkStatePath $netStatePath `
    -LogPath $netLogPath `
    -NetworkOutageThreshold 2 `
    -CustomNetworkChecker $mockNetChecker `
    -CustomHttpHandler $mockNetSender `
    -PassThru

Assert-Test -Name "Subsequent online run reports NetworkRecoverySent = False" -Condition ($resOnlineSubsequent.NetworkRecoverySent -eq $false)
Assert-Test -Name "Captured alerts count remains exactly 1 (no duplicate sent)" -Condition ($capturedNetAlerts.Count -eq 1)

# 3.5 ntfy Unavailable when network recovers -> error logged, state marked, no infinite loop
$capturedNetAlerts.Clear()
$simOnline = $false
# Trigger sustained outage state
$null = & $watchdogScript -NetworkStatePath $netStatePath -LogPath $netLogPath -NetworkOutageThreshold 1 -CustomNetworkChecker $mockNetChecker -CustomHttpHandler $mockNetSender -PassThru

# Recovery with failing ntfy endpoint
$simOnline = $true
$mockFailingNtfy = {
    param($Url, $Headers, $Body, $Attempt)
    throw [System.Net.WebException]::new("The remote server returned an error: (503) Server Unavailable.")
}

$resNtfyDown = & $watchdogScript `
    -NetworkStatePath $netStatePath `
    -LogPath $netLogPath `
    -NetworkOutageThreshold 1 `
    -CustomNetworkChecker $mockNetChecker `
    -CustomHttpHandler $mockFailingNtfy `
    -PassThru

Assert-Test -Name "Watchdog handles ntfy outage without unhandled crash" -Condition ($resNtfyDown -ne $null)
Assert-Test -Name "NetworkRecoverySent is False when ntfy delivery fails" -Condition ($resNtfyDown.NetworkRecoverySent -eq $false)
Assert-Test -Name "NetworkError captured sanitized error" -Condition ($resNtfyDown.NetworkError -match "503")

# Next cycle does not loop or retry endlessly
$resNtfyDownNext = & $watchdogScript `
    -NetworkStatePath $netStatePath `
    -LogPath $netLogPath `
    -NetworkOutageThreshold 1 `
    -CustomNetworkChecker $mockNetChecker `
    -CustomHttpHandler $mockFailingNtfy `
    -PassThru

Assert-Test -Name "Subsequent cycle skips duplicate alert attempt after failure" -Condition ($resNtfyDownNext.NetworkAlertSkipped -eq $true)

# ==============================================================================
# Suite 4: Quick Status Report (Get-NotificationForwarderStatus.ps1)
# ==============================================================================
Write-Host "`nTest Suite 4: Quick Status Report (Get-NotificationForwarderStatus.ps1)" -ForegroundColor White

$statusScript = Join-Path $projDir "Get-NotificationForwarderStatus.ps1"
Assert-Test -Name "Get-NotificationForwarderStatus.ps1 exists" -Condition (Test-Path $statusScript)

# 4.1 Healthy service status report (against production project dir)
$prodStatus = & $statusScript -ProjectDir $projDir -PassThru
Assert-Test -Name "Production status reports ProcessRunning = True" -Condition ($prodStatus.ProcessRunning -eq $true)
Assert-Test -Name "Production status returns valid ProcessId" -Condition ($prodStatus.ProcessId -gt 0) -Details "PID=$($prodStatus.ProcessId)"
Assert-Test -Name "Production status reports ForwarderTaskState = Running" -Condition ($prodStatus.ForwarderTaskState -eq "Running")
Assert-Test -Name "Production status reports WatchdogTaskState = Ready" -Condition ($prodStatus.WatchdogTaskState -eq "Ready")
Assert-Test -Name "Production status reports AllFilesPresent = True" -Condition ($prodStatus.AllFilesPresent -eq $true)
$expectedPrivacy = if (Test-Path (Join-Path $projDir "config.json")) {
    (Get-Content -Path (Join-Path $projDir "config.json") -Raw | ConvertFrom-Json).PrivacyMode
} else { "TitleOnly" }
Assert-Test -Name "Production status reports configured PrivacyMode ($expectedPrivacy)" -Condition ($prodStatus.PrivacyMode -eq $expectedPrivacy)
Assert-Test -Name "Production status reports AppFilterMode = Allowlist" -Condition ($prodStatus.AppFilterMode -eq "Allowlist")
Assert-Test -Name "Production status reports overall IsHealthy = True" -Condition ($prodStatus.IsHealthy -eq $true)

# 4.2 Read-only verification: check that PID is unchanged after running status script
$prodStatus2 = & $statusScript -ProjectDir $projDir -PassThru
Assert-Test -Name "Status report is read-only (PID unchanged)" -Condition ($prodStatus2.ProcessId -eq $prodStatus.ProcessId)

# 4.3 Missing file detection in sandbox
$sandboxDirFiles = Join-Path $env:TEMP ("SprintStatus_SandboxFiles_" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $sandboxDirFiles -Force | Out-Null
# Only copy some files, leaving Watchdog.ps1 missing
Copy-Item (Join-Path $projDir "Config.ps1") -Destination $sandboxDirFiles
Copy-Item (Join-Path $projDir "config.json") -Destination $sandboxDirFiles

$missingFileStatus = & $statusScript -ProjectDir $sandboxDirFiles -PassThru
Assert-Test -Name "Status report detects missing files" -Condition ($missingFileStatus.AllFilesPresent -eq $false)
Assert-Test -Name "Missing file status reports IsHealthy = False" -Condition ($missingFileStatus.IsHealthy -eq $false)
Assert-Test -Name "Missing file list includes Watchdog.ps1" -Condition ($missingFileStatus.MissingFiles -contains "Watchdog.ps1")

# 4.4 Missing task detection in sandbox
$missingTaskStatus = & $statusScript -ProjectDir $projDir -ForwarderTaskName "NonExistentTask12345" -PassThru
Assert-Test -Name "Status report detects missing scheduled task" -Condition ($missingTaskStatus.ForwarderTaskState -eq "Not Registered")
Assert-Test -Name "Missing task causes IsHealthy = False" -Condition ($missingTaskStatus.IsHealthy -eq $false)

# 4.5 CMD Launcher Verification
$cmdLauncher = Join-Path $projDir "NotificationForwarder Status.cmd"
Assert-Test -Name "NotificationForwarder Status.cmd exists in project dir" -Condition (Test-Path $cmdLauncher)
$cmdContent = if (Test-Path $cmdLauncher) { Get-Content $cmdLauncher -Raw } else { "" }
Assert-Test -Name "CMD launcher references Get-NotificationForwarderStatus.ps1" -Condition ($cmdContent -match "Get-NotificationForwarderStatus\.ps1")
Assert-Test -Name "CMD launcher includes -NoProfile -ExecutionPolicy Bypass" -Condition ($cmdContent -match "-NoProfile\s+-ExecutionPolicy\s+Bypass")

# ==============================================================================
# Suite 5: Security & Sanitization
# ==============================================================================
Write-Host "`nTest Suite 5: Security & Sanitization" -ForegroundColor White

$secretTopic5 = "my_private_topic_9999"
$secretToken5 = "tk_my_private_token_xyz123"
$rawSecretError = "Failed connecting to https://ntfy.sh/$secretTopic5 using Bearer $secretToken5 with Title='Secret Meeting' Body='Confidential Content'"

$sanitizedErr = Get-SanitizedMessage -InputMessage $rawSecretError -Config @{ NtfyTopic = $secretTopic5; NtfyToken = $secretToken5 }
Assert-Test -Name "Sanitizer removes raw secret topic" -Condition ($sanitizedErr -notmatch [regex]::Escape($secretTopic5))
Assert-Test -Name "Sanitizer removes raw secret token" -Condition ($sanitizedErr -notmatch [regex]::Escape($secretToken5))
Assert-Test -Name "Sanitizer removes raw URL" -Condition ($sanitizedErr -notmatch "https://ntfy\.sh")

# Cleanup sandboxes
Remove-Item -Path $sandboxDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $sandboxDirFiles -Recurse -Force -ErrorAction SilentlyContinue

# ==============================================================================
# Summary
# ==============================================================================
Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " Sprint Features Test Summary" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
$passed = ($testResults | Where-Object { $_.Status -eq "PASS" }).Count
$failed = ($testResults | Where-Object { $_.Status -eq "FAIL" }).Count
Write-Host "  Total Tests: $($testResults.Count)" -ForegroundColor White
Write-Host "  Passed:      $passed" -ForegroundColor Green
Write-Host "  Failed:      $failed" -ForegroundColor $(if ($failed -gt 0) { [ConsoleColor]::Red } else { [ConsoleColor]::Green })

if ($failed -gt 0) {
    exit 1
}
exit 0
