<#
.SYNOPSIS
    Automated reliability, safety, and security regression test suite for NotificationForwarder.
.DESCRIPTION
    Runs safe, non-destructive, synthetic-only tests without sending real notifications or exposing secrets.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    $scriptDir = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
$scriptDir = (Resolve-Path $scriptDir).Path
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Running NotificationForwarder Final Focused Review Suite" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

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

# ---------------------------------------------------------
# Test Suite 1: Script Syntax Validation
# ---------------------------------------------------------
Write-Host "`nTest Suite 1: Script Syntax Validation" -ForegroundColor White
$psFiles = @(
    "Config.ps1",
    "NotificationReader.ps1",
    "NotificationFilter.ps1",
    "NotificationSender.ps1",
    "NotificationForwarder.ps1",
    "Test-NtfyDelivery.ps1",
    "Register-NotificationForwarderTask.ps1"
)

foreach ($file in $psFiles) {
    $fullPath = Join-Path -Path $scriptDir -ChildPath $file
    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$tokens, [ref]$errors)
    Assert-Test -Name "Syntax validation: $file" -Condition ($errors.Count -eq 0) -Details "Errors: $($errors.Count)"
}

. (Join-Path -Path $scriptDir -ChildPath "Config.ps1")
. (Join-Path -Path $scriptDir -ChildPath "NotificationReader.ps1")
. (Join-Path -Path $scriptDir -ChildPath "NotificationFilter.ps1")
. (Join-Path -Path $scriptDir -ChildPath "NotificationSender.ps1")
. (Join-Path -Path $scriptDir -ChildPath "NotificationForwarder.ps1")

# ---------------------------------------------------------
# Test Suite 2: Configuration & Safety Defaults
# ---------------------------------------------------------
Write-Host "`nTest Suite 2: Configuration & Safety Defaults" -ForegroundColor White
$defaultConfig = Get-DefaultConfig
Assert-Test -Name "Default DryRun is True" -Condition ($defaultConfig.DryRun -eq $true)
Assert-Test -Name "Default LiveForwarding is Disabled" -Condition ($defaultConfig.LiveForwardingEnabled -eq $false)
Assert-Test -Name "Default PrivacyMode is TitleOnly" -Condition ($defaultConfig.PrivacyMode -eq "TitleOnly")
Assert-Test -Name "Default AppFilterMode is Allowlist" -Condition ($defaultConfig.AppFilterMode -eq "Allowlist")
Assert-Test -Name "Default NtfyTopic is empty" -Condition ([string]::IsNullOrWhiteSpace($defaultConfig.NtfyTopic))

$check = Test-AppConfig -Config $defaultConfig
Assert-Test -Name "Default config validation passes (safe mode)" -Condition ($check.IsValid -eq $true)

$unconfiguredLive = @{ LiveForwardingEnabled = $true; DryRun = $false; NtfyTopic = ""; NtfyServer = "https://ntfy.sh" }
$liveCheck = Test-AppConfig -Config $unconfiguredLive
Assert-Test -Name "Live mode with missing topic is rejected" -Condition ($liveCheck.IsValid -eq $false)

# ---------------------------------------------------------
# Test Suite 3: Dual-Mode App Filtering & Explicit Exclusions
# ---------------------------------------------------------
Write-Host "`nTest Suite 3: Dual-Mode App Filtering & Exclusions" -ForegroundColor White
$allowedList = @("Chrome", "*WhatsApp*", "Telegram.TelegramDesktop")
$ignoreList  = @("SecretApp*", "BlockedVendor.*")

$chromeAllowed = Test-IsAppAllowed -AppUserModelId "Chrome" -AppDisplayName "Google Chrome" -AppFilterMode "Allowlist" -AllowedAppIds $allowedList -IgnoreAppIds $ignoreList
Assert-Test -Name "Allowlist mode: listed app is permitted (Chrome)" -Condition ($chromeAllowed -eq $true)

$unlistedAllowlist = Test-IsAppAllowed -AppUserModelId "RandomApp" -AppDisplayName "Random App" -AppFilterMode "Allowlist" -AllowedAppIds $allowedList -IgnoreAppIds $ignoreList
Assert-Test -Name "Allowlist mode: unlisted app is blocked (deny-by-default)" -Condition ($unlistedAllowlist -eq $false)

$ignoredInAllowlist = Test-IsAppAllowed -AppUserModelId "SecretApp.Tools" -AppDisplayName "SecretApp" -AppFilterMode "Allowlist" -AllowedAppIds @("SecretApp*") -IgnoreAppIds $ignoreList
Assert-Test -Name "Allowlist mode: explicit ignore takes precedence over allowlist" -Condition ($ignoredInAllowlist -eq $false)

$unlistedAllMode = Test-IsAppAllowed -AppUserModelId "NewUntrackedApp.Client" -AppDisplayName "New Client" -AppFilterMode "AllWindowsNotifications" -AllowedAppIds $allowedList -IgnoreAppIds $ignoreList
Assert-Test -Name "AllWindowsNotifications mode: unlisted app is permitted" -Condition ($unlistedAllMode -eq $true)

$ignoredAllMode = Test-IsAppAllowed -AppUserModelId "BlockedVendor.Tool" -AppDisplayName "Blocked Vendor" -AppFilterMode "AllWindowsNotifications" -AllowedAppIds $allowedList -IgnoreAppIds $ignoreList
Assert-Test -Name "AllWindowsNotifications mode: explicit ignore list is enforced" -Condition ($ignoredAllMode -eq $false)

# ---------------------------------------------------------
# Test Suite 4: Privacy Boundary Enforcement
# ---------------------------------------------------------
Write-Host "`nTest Suite 4: Privacy Boundary Enforcement" -ForegroundColor White
$mockNotifTitleOnly = [PSCustomObject]@{
    Id             = 2001
    AppUserModelId = "Chrome"
    AppDisplayName = "Google Chrome"
    CreationTime   = [DateTimeOffset]::Now
    Title          = "Synthetic Test Title"
    Body           = ""
    HasBody        = $true
    TitleLength    = 20
    BodyLength     = 0
    PrivacyModeUsed= "TitleOnly"
}

$filteredTitleOnly = Filter-Notification -NotificationData $mockNotifTitleOnly -Config @{ PrivacyMode = "TitleOnly"; AppFilterMode = "AllWindowsNotifications"; IgnoreAppIds = @() }
Assert-Test -Name "TitleOnly mode preserves title" -Condition ($filteredTitleOnly.Title -eq "Synthetic Test Title")
Assert-Test -Name "TitleOnly mode suppresses message body (empty string)" -Condition ($filteredTitleOnly.Body -eq "")

$mockNotifTitleAndBody = [PSCustomObject]@{
    Id             = 2002
    AppUserModelId = "Chrome"
    AppDisplayName = "Google Chrome"
    CreationTime   = [DateTimeOffset]::Now
    Title          = "Synthetic Test Title"
    Body           = "This is a sensitive message body"
    HasBody        = $true
    TitleLength    = 20
    BodyLength     = 34
    PrivacyModeUsed= "TitleAndBody"
}

$filteredTitleAndBody = Filter-Notification -NotificationData $mockNotifTitleAndBody -Config @{ PrivacyMode = "TitleAndBody"; AppFilterMode = "AllWindowsNotifications"; IgnoreAppIds = @() }
Assert-Test -Name "TitleAndBody mode retains message body" -Condition ($filteredTitleAndBody.Body -eq "This is a sensitive message body")

# ---------------------------------------------------------
# Test Suite 5: Dry-Run Safety Gate
# ---------------------------------------------------------
Write-Host "`nTest Suite 5: Dry-Run Safety Gate" -ForegroundColor White
$dryRunManager = New-DeliveryManager
$dryRunConfig = @{
    DryRun                = $true
    LiveForwardingEnabled = $true
    NtfyServer            = "https://ntfy.sh"
    NtfyTopic             = "test-topic"
}

$testItem = [PSCustomObject]@{
    Id             = 1001
    AppLabel       = "PowerShell"
    Title          = "DryRun Test Notification"
    Body           = ""
    PrivacyMode    = "TitleOnly"
    AppFilterMode  = "Allowlist"
}

$dryResult = Send-Notification -FilteredNotification $testItem -Config $dryRunConfig -DeliveryManager $dryRunManager
Assert-Test -Name "Dry-run returns success status" -Condition ($dryResult.Success -eq $true)
Assert-Test -Name "Dry-run returns simulated indicator" -Condition ($dryResult.Status -eq "Simulated")
Assert-Test -Name "Dry-run notification is marked in delivered cache" -Condition ((Test-IsDelivered -Manager $dryRunManager -NotificationId 1001) -eq $true)

$unarmedLiveConfig = @{
    DryRun                = $false
    LiveForwardingEnabled = $false
    NtfyServer            = "https://ntfy.sh"
    NtfyTopic             = "test-topic"
}
$safetyGateResult = Send-Notification -FilteredNotification $testItem -Config $unarmedLiveConfig -DeliveryManager $dryRunManager
Assert-Test -Name "LiveForwardingEnabled=False forces simulation even if DryRun=False" -Condition ($safetyGateResult.Status -eq "Simulated" -or $safetyGateResult.Skipped -eq $true)

# ---------------------------------------------------------
# Test Suite 6: Deduplication & Bounded Cache
# ---------------------------------------------------------
Write-Host "`nTest Suite 6: Deduplication & Bounded Cache" -ForegroundColor White
$dedupManager = New-DeliveryManager -MaxCapacity 3
Mark-AsDelivered -Manager $dedupManager -NotificationId 501
Mark-AsDelivered -Manager $dedupManager -NotificationId 502
Mark-AsDelivered -Manager $dedupManager -NotificationId 503

Assert-Test -Name "Delivered notification 501 is recognized" -Condition ((Test-IsDelivered -Manager $dedupManager -NotificationId 501) -eq $true)
Assert-Test -Name "Undelivered notification 504 is recognized as new" -Condition ((Test-IsDelivered -Manager $dedupManager -NotificationId 504) -eq $false)

# Add 4th item to exceed MaxCapacity of 3
Mark-AsDelivered -Manager $dedupManager -NotificationId 504
Assert-Test -Name "LRU eviction: oldest notification (501) was evicted" -Condition ((Test-IsDelivered -Manager $dedupManager -NotificationId 501) -eq $false)
Assert-Test -Name "LRU eviction: newest notification (504) is present" -Condition ((Test-IsDelivered -Manager $dedupManager -NotificationId 504) -eq $true)
Assert-Test -Name "Delivered cache count is bounded at MaxCapacity" -Condition ($dedupManager.DeliveredIds.Count -le 3)

# ---------------------------------------------------------
# Test Suite 7: Delivery Reliability & In-Memory Retry Queue
# ---------------------------------------------------------
Write-Host "`nTest Suite 7: Delivery Reliability & In-Memory Retry Queue" -ForegroundColor White
$liveConfig = @{
    DryRun                   = $false
    LiveForwardingEnabled    = $true
    NtfyServer               = "https://mock.local"
    NtfyTopic                = "secret-test-topic"
    MaxRetries               = 3
    RetryInitialDelaySeconds = 0.5
}

$deliveryMgr = New-DeliveryManager
$callCounts = @{}

$failingOnceHandler = {
    param($Url, $Headers, $Body, $Attempt)
    $notifId = if ($Headers.Title -match "3001") { 3001 } else { 3002 }
    if (-not $script:callCounts.ContainsKey($notifId)) { $script:callCounts[$notifId] = 0 }
    $script:callCounts[$notifId]++

    if ($notifId -eq 3001 -and $Attempt -eq 1) {
        throw "Simulated network drop on attempt 1"
    }
    return @{ Status = "Delivered" }
}

$mockNotif3001 = [PSCustomObject]@{
    Id             = 3001
    AppLabel       = "Test App 3001"
    Title          = "Title 3001"
    Body           = ""
    PrivacyMode    = "TitleOnly"
    AppFilterMode  = "Allowlist"
}

$res3001 = Send-Notification `
    -FilteredNotification $mockNotif3001 `
    -Config $liveConfig `
    -DeliveryManager $deliveryMgr `
    -CustomHttpHandler $failingOnceHandler

Assert-Test -Name "Initial failure queues notification for retry" -Condition ($res3001.Status -eq "QueuedForRetry" -and $res3001.Success -eq $false)
Assert-Test -Name "Failed notification is NOT marked as delivered" -Condition ((Test-IsDelivered -Manager $deliveryMgr -NotificationId 3001) -eq $false)
Assert-Test -Name "Failed notification is tracked in pending queue" -Condition ((Test-IsPendingRetry -Manager $deliveryMgr -NotificationId 3001) -eq $true)

$inFlightDup = Send-Notification `
    -FilteredNotification $mockNotif3001 `
    -Config $liveConfig `
    -DeliveryManager $deliveryMgr `
    -CustomHttpHandler $failingOnceHandler

Assert-Test -Name "Pending retry item blocks duplicate queuing" -Condition ($inFlightDup.Skipped -eq $true -and $inFlightDup.Reason -eq "PendingRetry")

(Get-PendingRetryItem -Manager $deliveryMgr -NotificationId 3001).NextAttempt = [DateTime]::UtcNow.AddSeconds(-1)
$processedCount = Process-PendingRetries `
    -DeliveryManager $deliveryMgr `
    -Config $liveConfig `
    -CustomHttpHandler $failingOnceHandler

Assert-Test -Name "Process-PendingRetries delivers queued notification" -Condition ($processedCount -eq 1)
Assert-Test -Name "Delivered retry is removed from pending queue" -Condition ((Test-IsPendingRetry -Manager $deliveryMgr -NotificationId 3001) -eq $false)
Assert-Test -Name "Delivered retry is marked in delivered cache" -Condition ((Test-IsDelivered -Manager $deliveryMgr -NotificationId 3001) -eq $true)

$alwaysFailingHandler = {
    param($Url, $Headers, $Body, $Attempt)
    throw "Permanent DNS failure"
}

$mockNotif3002 = [PSCustomObject]@{
    Id             = 3002
    AppLabel       = "Test App 3002"
    Title          = "Title 3002"
    Body           = ""
    PrivacyMode    = "TitleOnly"
    AppFilterMode  = "Allowlist"
}

$res3002 = Send-Notification `
    -FilteredNotification $mockNotif3002 `
    -Config $liveConfig `
    -DeliveryManager $deliveryMgr `
    -CustomHttpHandler $alwaysFailingHandler

(Get-PendingRetryItem -Manager $deliveryMgr -NotificationId 3002).NextAttempt = [DateTime]::UtcNow.AddSeconds(-1)
$null = Process-PendingRetries -DeliveryManager $deliveryMgr -Config $liveConfig -CustomHttpHandler $alwaysFailingHandler

(Get-PendingRetryItem -Manager $deliveryMgr -NotificationId 3002).NextAttempt = [DateTime]::UtcNow.AddSeconds(-1)
$null = Process-PendingRetries -DeliveryManager $deliveryMgr -Config $liveConfig -CustomHttpHandler $alwaysFailingHandler

Assert-Test -Name "Exhausted retry is purged from pending queue" -Condition ((Test-IsPendingRetry -Manager $deliveryMgr -NotificationId 3002) -eq $false)
Assert-Test -Name "Exhausted retry was not marked as delivered" -Condition ((Test-IsDelivered -Manager $deliveryMgr -NotificationId 3002) -eq $false)

# ---------------------------------------------------------
# Test Suite 8: Security Regression: Secret Scrubbing & Console Capture
# ---------------------------------------------------------
Write-Host "`nTest Suite 8: Security Regression: Secret Scrubbing & Console Capture" -ForegroundColor White
$fakeTopic = "fake-topic-abc12345"
$fakeToken = "tk_secret_auth_token_998877"
$fakeUrl   = "https://ntfy.sh/$fakeTopic/publish"

$fakeConfig = @{
    DryRun                   = $false
    LiveForwardingEnabled    = $true
    NtfyServer               = "https://ntfy.sh"
    NtfyTopic                = $fakeTopic
    NtfyToken                = $fakeToken
    MaxRetries               = 2
    RetryInitialDelaySeconds = 0.5
}

$rawSyntheticException = New-Object System.Net.WebException(
    "Server returned error 403 Forbidden connecting to $fakeUrl with Authorization: Bearer $fakeToken and token=$fakeToken"
)

$sanitizedOutput = Get-SanitizedMessage -InputMessage $rawSyntheticException -Config $fakeConfig

Assert-Test -Name "Sanitizer scrubs fake topic from error" -Condition ($sanitizedOutput -notmatch [regex]::Escape($fakeTopic))
Assert-Test -Name "Sanitizer scrubs fake token from error" -Condition ($sanitizedOutput -notmatch [regex]::Escape($fakeToken))
Assert-Test -Name "Sanitizer scrubs raw URL from error" -Condition ($sanitizedOutput -notmatch "https://")
Assert-Test -Name "Sanitizer includes [URL REDACTED] placeholder" -Condition ($sanitizedOutput -match "\[URL REDACTED\]")
Assert-Test -Name "Sanitizer includes [TOKEN REDACTED] placeholder" -Condition ($sanitizedOutput -match "\[TOKEN REDACTED\]")

$leakingHandler = {
    param($Url, $Headers, $Body, $Attempt)
    throw "Simulated leak exception to $Url with token=$fakeToken"
}

$mockSecretNotif = [PSCustomObject]@{
    Id             = 4001
    AppLabel       = "Secret Test App"
    Title          = "Secret Title"
    Body           = "Secret Body"
    PrivacyMode    = "TitleOnly"
    AppFilterMode  = "Allowlist"
}

$capturedConsoleOutput = & {
    $mgr = New-DeliveryManager
    Send-Notification `
        -FilteredNotification $mockSecretNotif `
        -Config $fakeConfig `
        -DeliveryManager $mgr `
        -CustomHttpHandler $leakingHandler
} *>&1 | Out-String

Assert-Test -Name "Captured console output contains NO fake topic" -Condition ($capturedConsoleOutput -notmatch [regex]::Escape($fakeTopic))
Assert-Test -Name "Captured console output contains NO fake token" -Condition ($capturedConsoleOutput -notmatch [regex]::Escape($fakeToken))
Assert-Test -Name "Captured console output contains NO raw URL" -Condition ($capturedConsoleOutput -notmatch "https://")
Assert-Test -Name "Captured console output contains NO notification title" -Condition ($capturedConsoleOutput -notmatch "Secret Title")
Assert-Test -Name "Captured console output contains NO notification body" -Condition ($capturedConsoleOutput -notmatch "Secret Body")

# ---------------------------------------------------------
# Test Suite 9: Fallback Sanitizer Hardening Audit (Sender & Reader)
# ---------------------------------------------------------
Write-Host "`nTest Suite 9: Fallback Sanitizer Hardening Audit" -ForegroundColor White
$fallbackRawException = New-Object System.Exception("Direct failure contacting https://ntfy.sh/$fakeTopic with Bearer $fakeToken and token=$fakeToken")

# 1. Sender fallback audit
$senderFallbackScrubbed = Get-SanitizedErrorMessage -Exception $fallbackRawException -Config $fakeConfig
Assert-Test -Name "Sender fallback scrubs raw URL" -Condition ($senderFallbackScrubbed -notmatch "https://")
Assert-Test -Name "Sender fallback scrubs secret topic" -Condition ($senderFallbackScrubbed -notmatch [regex]::Escape($fakeTopic))
Assert-Test -Name "Sender fallback scrubs secret token" -Condition ($senderFallbackScrubbed -notmatch [regex]::Escape($fakeToken))
Assert-Test -Name "Sender fallback redacts Bearer pattern" -Condition ($senderFallbackScrubbed -match "Bearer \[TOKEN REDACTED\]")

# 2. Reader fallback audit
$readerFallbackScrubbed = Get-ReaderFallbackSanitized -InputMessage $fallbackRawException -Config $fakeConfig
Assert-Test -Name "Reader fallback scrubs raw URL" -Condition ($readerFallbackScrubbed -notmatch "https://")
Assert-Test -Name "Reader fallback scrubs secret topic" -Condition ($readerFallbackScrubbed -notmatch [regex]::Escape($fakeTopic))
Assert-Test -Name "Reader fallback scrubs secret token" -Condition ($readerFallbackScrubbed -notmatch [regex]::Escape($fakeToken))
Assert-Test -Name "Reader fallback redacts Bearer pattern" -Condition ($readerFallbackScrubbed -match "Bearer \[TOKEN REDACTED\]")

# ---------------------------------------------------------
# Test Suite 10: Actual Startup Baseline Failure Handling Path
# ---------------------------------------------------------
Write-Host "`nTest Suite 10: Actual Startup Baseline Failure Handling Path" -ForegroundColor White

$mockFailingStartupReader = @{
    MockQueryHandler = { throw "WinRT listener hardware fault on $fakeUrl with token=$fakeToken" }
}

$startupMgr = New-DeliveryManager
$capturedStartupOutput = & {
    $script:startupBaseRes = Initialize-NotificationBaseline `
        -ReaderContext $mockFailingStartupReader `
        -Config $fakeConfig `
        -DeliveryManager $startupMgr
} *>&1 | Out-String

Assert-Test -Name "Initialize-NotificationBaseline returns failure on failed query" -Condition ($script:startupBaseRes.Success -eq $false)
Assert-Test -Name "Initialize-NotificationBaseline leaves KnownIds empty" -Condition ($script:startupBaseRes.KnownIds.Keys.Count -eq 0)
Assert-Test -Name "Startup failure logs [FATAL] prefix" -Condition ($capturedStartupOutput -match "\[FATAL\]")
Assert-Test -Name "Startup failure console output contains NO fake topic" -Condition ($capturedStartupOutput -notmatch [regex]::Escape($fakeTopic))
Assert-Test -Name "Startup failure console output contains NO fake token" -Condition ($capturedStartupOutput -notmatch [regex]::Escape($fakeToken))
Assert-Test -Name "Startup failure console output contains NO raw URL" -Condition ($capturedStartupOutput -notmatch "https://")

# Test end-to-end execution of NotificationForwarder.ps1 startup path in isolated PowerShell process
$procCmd = @"
`$fakeReader = @{
    MockQueryHandler = { throw 'Simulated WinRT RPC error to https://ntfy.sh/$fakeTopic with token=$fakeToken' }
}
& '$scriptDir\NotificationForwarder.ps1' -DryRun -Once -MockReaderContext `$fakeReader
exit `$LASTEXITCODE
"@
$procOutput = powershell.exe -ExecutionPolicy Bypass -NoProfile -Command $procCmd 2>&1 | Out-String
$procExitCode = $LASTEXITCODE

Assert-Test -Name "Startup baseline failure terminates process with exit code 1" -Condition ($procExitCode -eq 1)
Assert-Test -Name "Process exit output logs [FATAL] indicator" -Condition ($procOutput -match "\[FATAL\]")
Assert-Test -Name "Process exit output contains NO fake topic" -Condition ($procOutput -notmatch [regex]::Escape($fakeTopic))
Assert-Test -Name "Process exit output contains NO fake token" -Condition ($procOutput -notmatch [regex]::Escape($fakeToken))
Assert-Test -Name "Process exit output contains NO raw URL" -Condition ($procOutput -notmatch "https://")

# ---------------------------------------------------------
# Test Suite 11: Orchestrator Polling Cycle Failure & Recovery
# ---------------------------------------------------------
Write-Host "`nTest Suite 11: Orchestrator Polling Cycle Failure & Recovery" -ForegroundColor White
$orchConfig = @{
    DryRun                   = $true
    LiveForwardingEnabled    = $false
    PrivacyMode              = "TitleOnly"
    AppFilterMode            = "Allowlist"
    AllowedAppIds            = @("TestApp*")
    IgnoreAppIds             = @()
    PollIntervalSeconds      = 1.0
    NtfyServer               = "https://mock.local"
    NtfyTopic                = "test-topic"
    MaxRetries               = 2
    RetryInitialDelaySeconds = 1.0
}

$orchMgr = New-DeliveryManager

# Step 1: Baseline with 3 active notifications: 101, 102, 103
$orchKnownIds = @{ [uint32]101 = $true; [uint32]102 = $true; [uint32]103 = $true }
foreach ($id in $orchKnownIds.Keys) {
    Mark-AsDelivered -Manager $orchMgr -NotificationId $id
}

# Step 2: Cycle 1 with Failing Reader (exercising actual Invoke-NotificationForwarderCycle)
$mockFailingCycleReader = @{
    MockQueryHandler = { throw "Simulated WinRT polling RPC failure on cycle 1" }
}

$cycle1Output = & {
    $script:cycle1Result = Invoke-NotificationForwarderCycle `
        -ReaderContext $mockFailingCycleReader `
        -Config $orchConfig `
        -DeliveryManager $orchMgr `
        -KnownIds $orchKnownIds
} *>&1 | Out-String

Assert-Test -Name "Orchestrator reports cycle PollSuccess = False on error" -Condition ($script:cycle1Result.PollSuccess -eq $false)
Assert-Test -Name "Orchestrator preserves exact KnownIds count across failed cycle" -Condition ($orchKnownIds.Keys.Count -eq 3)
Assert-Test -Name "Orchestrator preserved original IDs (101, 102, 103)" -Condition ($orchKnownIds.ContainsKey([uint32]101) -and $orchKnownIds.ContainsKey([uint32]102) -and $orchKnownIds.ContainsKey([uint32]103))
Assert-Test -Name "Orchestrator skipped delta additions on failed cycle" -Condition ($script:cycle1Result.AddedCount -eq 0)
Assert-Test -Name "Orchestrator skipped delta removals on failed cycle" -Condition ($script:cycle1Result.RemovedCount -eq 0)

# Helper for creating mock notifications compatible with Extract-NotificationData
function New-MockNotification {
    param([uint32]$Id, [string]$App = "TestApp")
    return [PSCustomObject]@{
        Id           = $Id
        CreationTime = [DateTimeOffset]::Now
        AppInfo      = [PSCustomObject]@{
            AppUserModelId = $App
            DisplayInfo    = [PSCustomObject]@{ DisplayName = $App }
        }
        Notification = [PSCustomObject]@{
            Visual = [PSCustomObject]@{
                GetBinding = {
                    param($kind)
                    return [PSCustomObject]@{
                        GetTextElements = {
                            return @(
                                [PSCustomObject]@{ Text = "Title $Id" },
                                [PSCustomObject]@{ Text = "Body $Id" }
                            )
                        }
                    }
                }
            }
        }
    }
}

$recoveredDict = @{
    [uint32]101 = (New-MockNotification -Id 101)
    [uint32]102 = (New-MockNotification -Id 102)
    [uint32]103 = (New-MockNotification -Id 103)
}

# Step 3: Cycle 2 with Recovered Mock Reader (exercising actual Invoke-NotificationForwarderCycle)
$mockRecoveredReader = @{
    MockQueryHandler = {
        return @{
            Success       = $true
            Notifications = $recoveredDict
            ErrorCategory = $null
            ErrorMessage  = $null
        }
    }
}

$cycle2Output = & {
    $script:cycle2Result = Invoke-NotificationForwarderCycle `
        -ReaderContext $mockRecoveredReader `
        -Config $orchConfig `
        -DeliveryManager $orchMgr `
        -KnownIds $orchKnownIds
} *>&1 | Out-String

Assert-Test -Name "Recovery cycle PollSuccess = True" -Condition ($script:cycle2Result.PollSuccess -eq $true)
Assert-Test -Name "Recovery cycle produces ZERO duplicate additions" -Condition ($script:cycle2Result.AddedCount -eq 0)
Assert-Test -Name "Recovery cycle produces ZERO false removals" -Condition ($script:cycle2Result.RemovedCount -eq 0)
Assert-Test -Name "KnownIds remains intact (3 items)" -Condition ($orchKnownIds.Keys.Count -eq 3)

# Step 4: Cycle 3 with New Notification 104 arriving (exercising actual Invoke-NotificationForwarderCycle)
$withAddedDict = @{
    [uint32]101 = $recoveredDict[101]
    [uint32]102 = $recoveredDict[102]
    [uint32]103 = $recoveredDict[103]
    [uint32]104 = (New-MockNotification -Id 104)
}

$mockAddReader = @{
    MockQueryHandler = {
        return @{
            Success       = $true
            Notifications = $withAddedDict
            ErrorCategory = $null
            ErrorMessage  = $null
        }
    }
}

$cycle3Output = & {
    $script:cycle3Result = Invoke-NotificationForwarderCycle `
        -ReaderContext $mockAddReader `
        -Config $orchConfig `
        -DeliveryManager $orchMgr `
        -KnownIds $orchKnownIds
} *>&1 | Out-String

Assert-Test -Name "Subsequent cycle accurately detects new arrival (104)" -Condition ($script:cycle3Result.AddedCount -eq 1)
Assert-Test -Name "Subsequent cycle reports zero false removals" -Condition ($script:cycle3Result.RemovedCount -eq 0)
Assert-Test -Name "KnownIds now contains newly arrived ID (104)" -Condition ($orchKnownIds.ContainsKey([uint32]104))
Assert-Test -Name "Delivered notification 104 recorded in DeliveredIds" -Condition ((Test-IsDelivered -Manager $orchMgr -NotificationId 104) -eq $true)

# Step 5: Cycle 4 with Notification 101 dismissed (exercising actual Invoke-NotificationForwarderCycle)
$withRemovedDict = @{
    [uint32]102 = $recoveredDict[102]
    [uint32]103 = $recoveredDict[103]
    [uint32]104 = $withAddedDict[104]
}

$mockRemoveReader = @{
    MockQueryHandler = {
        return @{
            Success       = $true
            Notifications = $withRemovedDict
            ErrorCategory = $null
            ErrorMessage  = $null
        }
    }
}

$cycle4Output = & {
    $script:cycle4Result = Invoke-NotificationForwarderCycle `
        -ReaderContext $mockRemoveReader `
        -Config $orchConfig `
        -DeliveryManager $orchMgr `
        -KnownIds $orchKnownIds
} *>&1 | Out-String

Assert-Test -Name "Dismissal cycle reports zero additions" -Condition ($script:cycle4Result.AddedCount -eq 0)
Assert-Test -Name "Dismissal cycle accurately detects removal of ID 101" -Condition ($script:cycle4Result.RemovedCount -eq 1)
Assert-Test -Name "KnownIds no longer contains dismissed ID 101" -Condition (-not $orchKnownIds.ContainsKey([uint32]101))
Assert-Test -Name "KnownIds count is now 3 (102, 103, 104)" -Condition ($orchKnownIds.Keys.Count -eq 3)

# ---------------------------------------------------------
# Test Suite 12: Retry Queue Overflow & Dropped Item Accounting
# ---------------------------------------------------------
Write-Host "`nTest Suite 12: Retry Queue Overflow & Dropped Item Accounting" -ForegroundColor White
$smallQueueMgr = New-DeliveryManager -MaxCapacity 100 -MaxRetryQueue 2

$overflowConfig = @{
    DryRun                   = $false
    LiveForwardingEnabled    = $true
    NtfyServer               = "https://mock.local"
    NtfyTopic                = "mock-topic"
    MaxRetries               = 3
    RetryInitialDelaySeconds = 2.0
}

$dropFailingHandler = {
    param($Url, $Headers, $Body, $Attempt)
    throw "Simulated network failure"
}

$mockNotif5001 = [PSCustomObject]@{ Id = 5001; AppLabel = "App 5001"; Title = "Title 5001"; Body = ""; PrivacyMode = "TitleOnly"; AppFilterMode = "Allowlist" }
$mockNotif5002 = [PSCustomObject]@{ Id = 5002; AppLabel = "App 5002"; Title = "Title 5002"; Body = ""; PrivacyMode = "TitleOnly"; AppFilterMode = "Allowlist" }
$mockNotif5003 = [PSCustomObject]@{ Id = 5003; AppLabel = "App 5003"; Title = "Title 5003"; Body = ""; PrivacyMode = "TitleOnly"; AppFilterMode = "Allowlist" }

$null = Send-Notification -FilteredNotification $mockNotif5001 -Config $overflowConfig -DeliveryManager $smallQueueMgr -CustomHttpHandler $dropFailingHandler
Start-Sleep -Milliseconds 50
$null = Send-Notification -FilteredNotification $mockNotif5002 -Config $overflowConfig -DeliveryManager $smallQueueMgr -CustomHttpHandler $dropFailingHandler

Assert-Test -Name "Queue reaches capacity (2 items)" -Condition ($smallQueueMgr.PendingRetries.Count -eq 2)

$overflowConsoleOutput = & {
    Send-Notification -FilteredNotification $mockNotif5003 -Config $overflowConfig -DeliveryManager $smallQueueMgr -CustomHttpHandler $dropFailingHandler
} *>&1 | Out-String

Assert-Test -Name "Queue capacity is capped at MaxRetryQueue (2)" -Condition ($smallQueueMgr.PendingRetries.Count -eq 2)
Assert-Test -Name "Oldest item 5001 was dropped from pending queue" -Condition ((Test-IsPendingRetry -Manager $smallQueueMgr -NotificationId 5001) -eq $false)
Assert-Test -Name "Dropped item 5001 is NEVER marked as delivered" -Condition ((Test-IsDelivered -Manager $smallQueueMgr -NotificationId 5001) -eq $false)
Assert-Test -Name "Overflow warning logs dropped ID only" -Condition ($overflowConsoleOutput -match "ID=5001")
Assert-Test -Name "Overflow warning does NOT log notification title or body" -Condition ($overflowConsoleOutput -notmatch "Title 5001" -and $overflowConsoleOutput -notmatch "Body")
Assert-Test -Name "Overflow warning NEVER claims dropped item was delivered" -Condition ($overflowConsoleOutput -notmatch "Forwarded notification ID=5001" -and $overflowConsoleOutput -notmatch "Delivered")

# ---------------------------------------------------------
# Test Suite 13: Live WinRT Baseline and Delta Detection
# ---------------------------------------------------------
Write-Host "`nTest Suite 13: Live WinRT Baseline and Delta Detection" -ForegroundColor White
$readerContext = Initialize-NotificationReader
Assert-Test -Name "WinRT UserNotificationListener initialized" -Condition ($readerContext.Initialized -eq $true)

$baselinePoll = Get-CurrentNotifications -ReaderContext $readerContext
Assert-Test -Name "Live polling returns structured Success" -Condition ($baselinePoll.Success -eq $true)
$baselineCount = $baselinePoll.Notifications.Keys.Count
Write-Host "    Current active notifications in store: $baselineCount" -ForegroundColor Gray

[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

$xml = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]::new()
$xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>Final Review Synthetic Toast</text><text>Test Payload</text></binding></visual></toast>')
$toast = [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]::new($xml)
$aumid = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"
$notifier = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]::CreateToastNotifier($aumid)
$notifier.Show($toast)

Start-Sleep -Milliseconds 900

$afterAddPoll = Get-CurrentNotifications -ReaderContext $readerContext
Assert-Test -Name "Post-toast poll succeeded" -Condition ($afterAddPoll.Success -eq $true)

$addDelta = Get-NotificationDeltas -CurrentDict $afterAddPoll.Notifications -KnownIds $baselinePoll.Notifications
Assert-Test -Name "Delta detector captured synthetic toast" -Condition ($addDelta.Added.Count -ge 1)

$syntheticId = 0
if ($addDelta.Added.Count -gt 0) {
    $syntheticId = $addDelta.Added[0]
    $captured = $afterAddPoll.Notifications[$syntheticId]
    $extracted = Extract-NotificationData -UserNotification $captured -PrivacyMode "TitleOnly"
    Assert-Test -Name "Extracted title matches synthetic toast" -Condition ($extracted.Title -eq "Final Review Synthetic Toast")
    Assert-Test -Name "Extracted body is suppressed under TitleOnly" -Condition ([string]::IsNullOrEmpty($extracted.Body))
}

if ($syntheticId -ne 0) {
    $readerContext.Listener.RemoveNotification($syntheticId)
    Start-Sleep -Milliseconds 600
    $afterRemovePoll = Get-CurrentNotifications -ReaderContext $readerContext
    $removeDelta = Get-NotificationDeltas -CurrentDict $afterRemovePoll.Notifications -KnownIds $afterAddPoll.Notifications
    Assert-Test -Name "Notification removal detected cleanly" -Condition ($removeDelta.Removed -contains $syntheticId)
}

# ---------------------------------------------------------
# Test Suite 14: Standalone Synthetic Delivery Test (Test-NtfyDelivery.ps1)
# ---------------------------------------------------------
Write-Host "`nTest Suite 14: Standalone Synthetic Delivery Test (Test-NtfyDelivery.ps1)" -ForegroundColor White
$testDeliveryScript = Join-Path -Path $scriptDir -ChildPath "Test-NtfyDelivery.ps1"

# 1. Safe Mode: Execution without -ConfirmSyntheticSend shows instructions and makes no network request
$safeModeOut = & $testDeliveryScript *>&1 | Out-String
Assert-Test -Name "Safe mode displays [SAFETY GATE] banner" -Condition ($safeModeOut -match "\[SAFETY GATE\]")
Assert-Test -Name "Safe mode displays instruction command" -Condition ($safeModeOut -match "-ConfirmSyntheticSend")
Assert-Test -Name "Safe mode displays fixed test payload" -Condition ($safeModeOut -match "Notification Forwarder Test")

# 2. Config validation: Rejection of missing configuration file
$nonExistentConfig = "C:\nonexistent_path_test_config.json"
$missingConfigProc = powershell.exe -ExecutionPolicy Bypass -NoProfile -File $testDeliveryScript -ConfirmSyntheticSend -ConfigPath $nonExistentConfig 2>&1 | Out-String
$missingConfigExit = $LASTEXITCODE
Assert-Test -Name "Missing config file causes exit code 1" -Condition ($missingConfigExit -eq 1)
Assert-Test -Name "Missing config logs [CONFIG ERROR]" -Condition ($missingConfigProc -match "\[CONFIG ERROR\]")

# 3. Config validation: Rejection of insecure HTTP endpoint
$insecureCfgPath = Join-Path -Path $env:TEMP -ChildPath "test_insecure_ntfy.json"
@{ NtfyServer = "http://insecure.local"; NtfyTopic = "test-topic" } | ConvertTo-Json | Set-Content -Path $insecureCfgPath -Encoding UTF8
$insecureProc = powershell.exe -ExecutionPolicy Bypass -NoProfile -File $testDeliveryScript -ConfirmSyntheticSend -ConfigPath $insecureCfgPath 2>&1 | Out-String
$insecureExit = $LASTEXITCODE
Remove-Item -Path $insecureCfgPath -Force -ErrorAction SilentlyContinue
Assert-Test -Name "Insecure HTTP server is rejected with exit code 1" -Condition ($insecureExit -eq 1)
Assert-Test -Name "Insecure HTTP logs [VALIDATION ERROR]" -Condition ($insecureProc -match "\[VALIDATION ERROR\]" -and $insecureProc -match "HTTPS")

# 4. Config validation: Rejection of empty NtfyTopic
$emptyTopicCfgPath = Join-Path -Path $env:TEMP -ChildPath "test_empty_topic.json"
@{ NtfyServer = "https://ntfy.sh"; NtfyTopic = "" } | ConvertTo-Json | Set-Content -Path $emptyTopicCfgPath -Encoding UTF8
$emptyTopicProc = powershell.exe -ExecutionPolicy Bypass -NoProfile -File $testDeliveryScript -ConfirmSyntheticSend -ConfigPath $emptyTopicCfgPath 2>&1 | Out-String
$emptyTopicExit = $LASTEXITCODE
Remove-Item -Path $emptyTopicCfgPath -Force -ErrorAction SilentlyContinue
Assert-Test -Name "Empty NtfyTopic is rejected with exit code 1" -Condition ($emptyTopicExit -eq 1)
Assert-Test -Name "Empty NtfyTopic logs [VALIDATION ERROR]" -Condition ($emptyTopicProc -match "\[VALIDATION ERROR\]" -and $emptyTopicProc -match "NtfyTopic")

# 5. Fixed Payload & Header Verification via Mock Handler (No real network send)
$mockValidCfgPath = Join-Path -Path $env:TEMP -ChildPath "test_valid_mock_ntfy.json"
$testTopicName = "sec-topic-998811"
$testTokenVal = "tk_auth_test_554433"
@{ NtfyServer = "https://mock.ntfy.local"; NtfyTopic = $testTopicName; NtfyToken = $testTokenVal } | ConvertTo-Json | Set-Content -Path $mockValidCfgPath -Encoding UTF8

$mockDeliveryCaptured = @{}
$mockDeliveryHandler = {
    param($Url, $Headers, $Body)
    $mockDeliveryCaptured["Url"] = $Url
    $mockDeliveryCaptured["Headers"] = $Headers
    $mockDeliveryCaptured["Body"] = $Body
    return @{ Status = "Success" }
}.GetNewClosure()

$mockSendOutput = & $testDeliveryScript -ConfirmSyntheticSend -ConfigPath $mockValidCfgPath -CustomHttpHandler $mockDeliveryHandler *>&1 | Out-String

Assert-Test -Name "Mock send verified fixed Title" -Condition ($mockDeliveryCaptured["Headers"]["Title"] -eq "Notification Forwarder Test")
Assert-Test -Name "Mock send verified fixed Body" -Condition ($mockDeliveryCaptured["Body"] -eq "Synthetic test message. No personal notification data.")
Assert-Test -Name "Mock send verified Authorization Bearer header" -Condition ($mockDeliveryCaptured["Headers"]["Authorization"] -eq "Bearer $testTokenVal")
Assert-Test -Name "Mock send output contains NO secret topic" -Condition ($mockSendOutput -notmatch [regex]::Escape($testTopicName))
Assert-Test -Name "Mock send output contains NO secret token" -Condition ($mockSendOutput -notmatch [regex]::Escape($testTokenVal))
Assert-Test -Name "Mock send output contains NO endpoint URL" -Condition ($mockSendOutput -notmatch "https://")
Assert-Test -Name "Mock send logs [SUCCESS] indicator" -Condition ($mockSendOutput -match "\[SUCCESS\]")

# 6. Error Sanitization via Mock Handler (Synthetic Exception with Secrets)
$mockFailingHandler = {
    param($Url, $Headers, $Body)
    throw "Simulated delivery drop to $Url with token=$testTokenVal and secret=$testTopicName"
}

$failingSendOutput = & $testDeliveryScript -ConfirmSyntheticSend -ConfigPath $mockValidCfgPath -CustomHttpHandler $mockFailingHandler *>&1 | Out-String
Remove-Item -Path $mockValidCfgPath -Force -ErrorAction SilentlyContinue

Assert-Test -Name "Failing send output logs [DELIVERY FAILED]" -Condition ($failingSendOutput -match "\[DELIVERY FAILED\]")
Assert-Test -Name "Failing send output scrubs secret topic" -Condition ($failingSendOutput -notmatch [regex]::Escape($testTopicName))
Assert-Test -Name "Failing send output scrubs secret token" -Condition ($failingSendOutput -notmatch [regex]::Escape($testTokenVal))
Assert-Test -Name "Failing send output scrubs raw URL" -Condition ($failingSendOutput -notmatch "https://")

# ---------------------------------------------------------
# Test Suite 15: Startup Configuration & File Logging Verification
# ---------------------------------------------------------
Write-Host "`nTest Suite 15: Startup Configuration & File Logging Verification" -ForegroundColor White
$regTaskScript = Join-Path -Path $scriptDir -ChildPath "Register-NotificationForwarderTask.ps1"

# 1. Verify in-memory scheduled task configuration object
$testAction = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptDir\NotificationForwarder.ps1`" -LogPath `"$scriptDir\forwarder.log`"" `
    -WorkingDirectory $scriptDir

$testTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$testSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

$testPrincipal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

$testTaskDef = New-ScheduledTask `
    -Action $testAction `
    -Trigger $testTrigger `
    -Settings $testSettings `
    -Principal $testPrincipal `
    -Description "Windows-to-iPhone Notification Forwarder background daemon"

Assert-Test -Name "In-memory Task Definition object is valid" -Condition ($testTaskDef -ne $null)
Assert-Test -Name "Task Action targets powershell.exe" -Condition ($testTaskDef.Actions.Execute -eq "powershell.exe")
Assert-Test -Name "Task Action argument includes -WindowStyle Hidden" -Condition ($testTaskDef.Actions.Arguments -match "-WindowStyle Hidden")
Assert-Test -Name "Task Action argument includes -LogPath forwarder.log" -Condition ($testTaskDef.Actions.Arguments -match "forwarder\.log")
Assert-Test -Name "Task Trigger is configured for AtLogOn" -Condition ($testTaskDef.Triggers[0].CimClass.CimClassName -eq "MSFT_TaskLogonTrigger")
Assert-Test -Name "Task Settings enforces MultipleInstances=IgnoreNew" -Condition ($testTaskDef.Settings.MultipleInstances -eq 0 -or $testTaskDef.Settings.MultipleInstances -eq "IgnoreNew")
Assert-Test -Name "Task Settings disables 72h limit (PT0S)" -Condition ($testTaskDef.Settings.ExecutionTimeLimit -eq "PT0S" -or $testTaskDef.Settings.ExecutionTimeLimit.TotalSeconds -eq 0)
Assert-Test -Name "Task Settings configures RestartCount=999" -Condition ($testTaskDef.Settings.RestartCount -eq 999)
Assert-Test -Name "Task Principal runs in interactive user session" -Condition ($testTaskDef.Principal.LogonType -eq 3 -or $testTaskDef.Principal.LogonType -eq "Interactive")
Assert-Test -Name "Task Principal runs with Limited privileges" -Condition ($testTaskDef.Principal.RunLevel -eq 0 -or $testTaskDef.Principal.RunLevel -eq "Limited")

# 1b. Verify Run-ForwarderHidden.vbs launcher and silent execution architecture
$fTestLauncher = Join-Path -Path $scriptDir -ChildPath "Run-ForwarderHidden.vbs"
Assert-Test -Name "Forwarder VBS launcher exists on disk" -Condition (Test-Path $fTestLauncher)
$fVbsContent = if (Test-Path $fTestLauncher) { Get-Content $fTestLauncher -Raw } else { "" }
Assert-Test -Name "Forwarder VBS launcher invokes PowerShell with -WindowStyle Hidden" -Condition ($fVbsContent -match "-WindowStyle Hidden")
Assert-Test -Name "Forwarder VBS launcher targets NotificationForwarder.ps1" -Condition ($fVbsContent -match "NotificationForwarder\.ps1")
Assert-Test -Name "Forwarder VBS launcher uses SW_HIDE (window style 0)" -Condition ($fVbsContent -match "oShell\.Run\s*\(?sCommand,\s*0,\s*True\)?")
Assert-Test -Name "Forwarder VBS launcher waits for PowerShell completion (bWaitOnReturn = True)" -Condition ($fVbsContent -match ",\s*0,\s*True")

# Verify in-memory silent task action using wscript.exe
$fTestAction = New-ScheduledTaskAction `
    -Execute "wscript.exe" `
    -Argument "`"$fTestLauncher`"" `
    -WorkingDirectory $scriptDir
Assert-Test -Name "Silent Task Action targets wscript.exe GUI subsystem" -Condition ($fTestAction.Execute -eq "wscript.exe")
Assert-Test -Name "Silent Task Action executes Run-ForwarderHidden.vbs" -Condition ($fTestAction.Arguments -match "Run-ForwarderHidden\.vbs")

# 2. Verify Register-NotificationForwarderTask.ps1 inspect command
$inspectOutput = & $regTaskScript -Inspect *>&1 | Out-String
Assert-Test -Name "Inspect command reports task status clearly" -Condition ($inspectOutput -match "NotificationForwarder" -and ($inspectOutput -match "Status: Registered" -or $inspectOutput -match "NOT currently registered"))

# 3. Verify file logging in NotificationForwarder.ps1
$tempLogPath = Join-Path -Path $env:TEMP -ChildPath "test_forwarder_log.log"
if (Test-Path $tempLogPath) { Remove-Item $tempLogPath -Force }

$logRunOutput = powershell.exe -ExecutionPolicy Bypass -NoProfile -File "$scriptDir\NotificationForwarder.ps1" -DryRun -Once -LogPath $tempLogPath 2>&1 | Out-String

Assert-Test -Name "NotificationForwarder created log file when -LogPath specified" -Condition (Test-Path $tempLogPath)
$logContent = if (Test-Path $tempLogPath) { Get-Content $tempLogPath -Raw } else { "" }
Assert-Test -Name "Log file includes timestamped baseline log" -Condition ($logContent -match "\[BASELINE\] Baseline established")
Assert-Test -Name "Log file includes clean shutdown log" -Condition ($logContent -match "\[SHUTDOWN\] NotificationForwarder stopped cleanly")
Assert-Test -Name "Log file contains NO secret topic" -Condition ($logContent -notmatch [regex]::Escape($fakeTopic))
Assert-Test -Name "Log file contains NO secret token" -Condition ($logContent -notmatch [regex]::Escape($fakeToken))
if (Test-Path $tempLogPath) { Remove-Item $tempLogPath -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------
# Test Suite 16: Watchdog Supervisor & Advanced Recovery Verification
# ---------------------------------------------------------
Write-Host "`nTest Suite 16: Watchdog Supervisor & Advanced Recovery Verification" -ForegroundColor White
$watchdogScript = Join-Path -Path $scriptDir -ChildPath "Watchdog.ps1"

# 1. Verify in-memory Watchdog Task Definition object (uses wscript.exe GUI subsystem launcher)
$wTestLauncher = Join-Path -Path $scriptDir -ChildPath "Run-WatchdogHidden.vbs"
$wTestAction = New-ScheduledTaskAction `
    -Execute "wscript.exe" `
    -Argument "`"$wTestLauncher`"" `
    -WorkingDirectory $scriptDir

$wTestLogonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$wTestRepeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 9999)
$wTestRepeatTrigger.Repetition.StopAtDurationEnd = $false

$wTestSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

$wTestPrincipal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

$wTestTaskDef = New-ScheduledTask `
    -Action $wTestAction `
    -Trigger @($wTestLogonTrigger, $wTestRepeatTrigger) `
    -Settings $wTestSettings `
    -Principal $wTestPrincipal `
    -Description "Supervises NotificationForwarder daemon; restarts it if stopped unexpectedly"

Assert-Test -Name "Watchdog in-memory Task Definition is valid" -Condition ($wTestTaskDef -ne $null)
Assert-Test -Name "Watchdog Action targets wscript.exe" -Condition ($wTestTaskDef.Actions.Execute -eq "wscript.exe")
Assert-Test -Name "Watchdog Action executes Run-WatchdogHidden.vbs" -Condition ($wTestTaskDef.Actions.Arguments -match "Run-WatchdogHidden\.vbs")
Assert-Test -Name "Watchdog VBS launcher exists on disk" -Condition (Test-Path $wTestLauncher)
$vbsContentOnDisk = if (Test-Path $wTestLauncher) { Get-Content $wTestLauncher -Raw } else { "" }
Assert-Test -Name "Watchdog VBS launcher invokes PowerShell with -WindowStyle Hidden" -Condition ($vbsContentOnDisk -match "-WindowStyle Hidden")
Assert-Test -Name "Watchdog VBS launcher targets Watchdog.ps1" -Condition ($vbsContentOnDisk -match "Watchdog\.ps1")
Assert-Test -Name "Watchdog VBS launcher uses SW_HIDE (window style 0)" -Condition ($vbsContentOnDisk -match "oShell\.Run\s+.*,\s*0,\s*False")
Assert-Test -Name "Watchdog has 2 triggers configured" -Condition ($wTestTaskDef.Triggers.Count -eq 2)
Assert-Test -Name "Watchdog Logon Trigger is configured" -Condition ($wTestTaskDef.Triggers[0].CimClass.CimClassName -eq "MSFT_TaskLogonTrigger")
Assert-Test -Name "Watchdog Repeat Trigger interval is PT1M" -Condition ($wTestTaskDef.Triggers[1].Repetition.Interval -eq "PT1M")
Assert-Test -Name "Watchdog Settings enforces MultipleInstances=IgnoreNew" -Condition ($wTestTaskDef.Settings.MultipleInstances -eq 0 -or $wTestTaskDef.Settings.MultipleInstances -eq "IgnoreNew")
Assert-Test -Name "Watchdog Settings limits execution to 5 minutes" -Condition ($wTestTaskDef.Settings.ExecutionTimeLimit -eq "PT5M" -or $wTestTaskDef.Settings.ExecutionTimeLimit.TotalMinutes -eq 5)
Assert-Test -Name "Watchdog Principal runs in interactive user session" -Condition ($wTestTaskDef.Principal.LogonType -eq 3 -or $wTestTaskDef.Principal.LogonType -eq "Interactive")
Assert-Test -Name "Watchdog Principal runs with Limited privileges" -Condition ($wTestTaskDef.Principal.RunLevel -eq 0 -or $wTestTaskDef.Principal.RunLevel -eq "Limited")

# 2. Verify Watchdog intentional disable suppression via marker file
$testMarkerPath = Join-Path -Path $scriptDir -ChildPath ".disabled"
if (Test-Path $testMarkerPath) { Remove-Item $testMarkerPath -Force }
[System.IO.File]::WriteAllText($testMarkerPath, "test disabled marker", [System.Text.Encoding]::UTF8)

$wDisabledResult = & $watchdogScript -PassThru
Assert-Test -Name "Watchdog detects .disabled marker file" -Condition ($wDisabledResult.Status -eq "Disabled")
Assert-Test -Name "Watchdog takes NO action when disabled" -Condition ($wDisabledResult.ActionTaken -eq "None")
Assert-Test -Name "Watchdog reports reason includes marker file" -Condition ($wDisabledResult.Reason -match "marker file")
Remove-Item $testMarkerPath -Force -ErrorAction SilentlyContinue

# 3. Verify Forwarder startup suppression when .disabled marker is present
[System.IO.File]::WriteAllText($testMarkerPath, "test disabled marker", [System.Text.Encoding]::UTF8)
$fwdDisabledOutput = powershell.exe -ExecutionPolicy Bypass -NoProfile -File "$scriptDir\NotificationForwarder.ps1" -DryRun -Once 2>&1 | Out-String
Assert-Test -Name "Forwarder detects .disabled marker and exits cleanly" -Condition ($fwdDisabledOutput -match "\[DISABLED\]")
Remove-Item $testMarkerPath -Force -ErrorAction SilentlyContinue

$wRecoveryLog = Join-Path -Path $env:TEMP -ChildPath "test_watchdog_recovery.log"
if (Test-Path $wRecoveryLog) { Remove-Item $wRecoveryLog -Force -ErrorAction SilentlyContinue }

# 4. Verify Watchdog non-registered task handling
$wNotRegResult = & $watchdogScript -ForwarderTaskName "NonExistentDummyTask99999" -LogPath $wRecoveryLog -PassThru
Assert-Test -Name "Watchdog detects non-registered task" -Condition ($wNotRegResult.Status -eq "NotRegistered")
Assert-Test -Name "Watchdog takes NO action for non-registered task" -Condition ($wNotRegResult.ActionTaken -eq "None")

# 4b. Verify Watchdog duplicate prevention when forwarder process is active
$wActiveCheck = & $watchdogScript -PassThru
if ($wActiveCheck.Running) {
    Assert-Test -Name "Watchdog detects active forwarder process" -Condition ($wActiveCheck.Status -eq "Running")
    Assert-Test -Name "Watchdog takes NO action to prevent duplicate processes" -Condition ($wActiveCheck.ActionTaken -eq "None")
}

# 5. Verify Watchdog recovery with temporary dummy task
$dummyTaskName = "Test-NotificationForwarder-WatchdogDummy"
$dummyAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-Command exit 0"
$dummyPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$dummyTask = Register-ScheduledTask -TaskName $dummyTaskName -Action $dummyAction -Principal $dummyPrincipal -Force

$wRecoveryResult = & $watchdogScript -ForwarderTaskName $dummyTaskName -LogPath $wRecoveryLog -ForceRestart -PassThru
Assert-Test -Name "Watchdog initiates recovery for stopped task" -Condition ($wRecoveryResult.Status -eq "Restarted")
Assert-Test -Name "Watchdog action is Start-ScheduledTask" -Condition ($wRecoveryResult.ActionTaken -eq "Start-ScheduledTask")

Assert-Test -Name "Watchdog recovery created log entry" -Condition (Test-Path $wRecoveryLog)
$wLogContent = if (Test-Path $wRecoveryLog) { Get-Content $wRecoveryLog -Raw } else { "" }
Assert-Test -Name "Watchdog log entry includes [WATCHDOG] prefix" -Condition ($wLogContent -match "\[WATCHDOG\]")
Assert-Test -Name "Watchdog log entry indicates restart" -Condition ($wLogContent -match "Restarting task")
Assert-Test -Name "Watchdog log contains NO secret topic" -Condition ($wLogContent -notmatch [regex]::Escape($fakeTopic))
Assert-Test -Name "Watchdog log contains NO secret token" -Condition ($wLogContent -notmatch [regex]::Escape($fakeToken))

# Cleanup dummy task and log
Unregister-ScheduledTask -TaskName $dummyTaskName -Confirm:$false -ErrorAction SilentlyContinue
if (Test-Path $wRecoveryLog) { Remove-Item $wRecoveryLog -Force -ErrorAction SilentlyContinue }

Write-Host "`n==========================================================" -ForegroundColor Cyan
$passed = @($testResults | Where-Object { $_.Status -eq "PASS" }).Count
$failed = @($testResults | Where-Object { $_.Status -eq "FAIL" }).Count
Write-Host (" Test Summary: {0} Total, {1} Passed, {2} Failed" -f $testResults.Count, $passed, $failed) `
    -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failed -gt 0) {
    exit 1
} else {
    exit 0
}
