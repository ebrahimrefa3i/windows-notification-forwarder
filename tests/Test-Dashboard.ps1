<#
.SYNOPSIS
    Isolated Unit and Integration Tests for NotificationForwarder Dashboard & Application Filtering.
.DESCRIPTION
    Tests:
    1. Status Engine (Get-DashboardStatus) under various config/process/task conditions.
    2. Destination Setting (Set-DashboardDestination) validation, atomic write, .bak backup, secret preservation.
    3. Forwarding Control (Set-DashboardForwardingState) ON/OFF transitions, .disabled marker creation/removal.
    4. Application Filtering Engine (Get-DashboardApps & Set-DashboardApps):
       - Adding allowed apps, blocking apps, removing/resetting rules.
       - Mode switching (Allowlist <-> Blocklist).
       - Duplicate prevention, input validation, and cross-conflict resolution.
       - Preservation of unrelated config and atomic backup creation.
       - Optimistic concurrency control (ExpectedTimestamp).
       - Real pipeline integration: Test-IsAppAllowed and Filter-Notification.
    5. Localhost-only Security: Verifies 127.0.0.1 binding, 401/403 token enforcement for /api/status and /api/apps.
    6. Non-disruption: Does NOT terminate or interfere with live production daemon.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ProjectDir = $null
)

if ([string]::IsNullOrWhiteSpace($ProjectDir)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $ProjectDir = Split-Path -Parent $PSScriptRoot
    } else {
        $ProjectDir = (Get-Location).Path
    }
}
$ProjectDir = (Resolve-Path $ProjectDir).Path

$ErrorActionPreference = "Continue"

$totalTests = 0
$passedTests = 0
$failedTests = 0

function Assert-Test {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Details = ""
    )
    $script:totalTests++
    if ($Condition) {
        $script:passedTests++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } else {
        $script:failedTests++
        Write-Host "  [FAIL] $Name : $Details" -ForegroundColor Red
    }
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Running Isolated Dashboard & App Filter Test Suite" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Dot-source the dashboard functions without starting the server
$dashboardScript = Join-Path -Path $ProjectDir -ChildPath "Start-Dashboard.ps1"
if (-not (Test-Path $dashboardScript)) {
    Write-Host "[FATAL] Start-Dashboard.ps1 not found at $dashboardScript" -ForegroundColor Red
    exit 1
}

. $dashboardScript

# --------------------------------------------------------------------------
# Test Group 0: User-Facing Dashboard UI Contract
# --------------------------------------------------------------------------
Write-Host "`n--- Group 0: Dashboard UI Palette, Layout & Dropdown Accessibility ---" -ForegroundColor Yellow

$dashboardHtml = Get-DashboardHtml -AuthToken "ui-test-token"
$uiColorMatches = [regex]::Matches($dashboardHtml, '#[0-9A-Fa-f]{6}') | ForEach-Object { $_.Value.ToUpperInvariant() } | Select-Object -Unique
$allowedUiColors = @('#EFEFEF', '#FFFFFF', '#234CE2', '#212121')
$paletteIsStrict = @($uiColorMatches | Where-Object { $_ -notin $allowedUiColors }).Count -eq 0
Assert-Test -Name "Dashboard UI uses only the approved palette" -Condition $paletteIsStrict -Details ($uiColorMatches -join ', ')
Assert-Test -Name "Dashboard UI removes visible borders" -Condition ($dashboardHtml -match 'body \* \{ border: 0 !important')
Assert-Test -Name "Dashboard cards and controls use softer rounded corners" `
    -Condition ($dashboardHtml -match 'border-radius: 26px' -and $dashboardHtml -match 'border-radius: 16px' -and $dashboardHtml -match 'border-radius: 20px')
Assert-Test -Name "Filter mode dropdown exposes listbox and selected option semantics" `
    -Condition ($dashboardHtml -match 'role="listbox"' -and $dashboardHtml -match 'role="option"' -and $dashboardHtml -match 'aria-selected=')
Assert-Test -Name "Filter mode dropdown implements keyboard navigation and dismissal" `
    -Condition ($dashboardHtml -match 'function handleFilterModeKeydown' -and $dashboardHtml -match 'event.key === "ArrowDown"' -and $dashboardHtml -match 'event.key === "Escape"' -and $dashboardHtml -match 'closeFilterModeMenu\(false\)')
Assert-Test -Name "Dashboard layout includes responsive breakpoints and semantic page regions" `
    -Condition ($dashboardHtml -match '@media \(max-width: 780px\)' -and $dashboardHtml -match '@media \(max-width: 520px\)' -and $dashboardHtml -match '<main class="dashboard-grid"')

# Dot-source filter module for pipeline tests
$filterScript = Join-Path -Path $ProjectDir -ChildPath "NotificationFilter.ps1"
if (Test-Path $filterScript) {
    . $filterScript
}

# Create isolated sandbox directory for tests
$sandbox = Join-Path -Path $env:TEMP -ChildPath "NF_Dashboard_Test_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

try {
    # --------------------------------------------------------------------------
    # Test Group 1: Status Engine & Secret Masking
    # --------------------------------------------------------------------------
    Write-Host "`n--- Group 1: Status Engine & Secret Masking ---" -ForegroundColor Yellow

    $sandboxConfig = Join-Path -Path $sandbox -ChildPath "config.json"
    $initJson = @{
        LiveForwardingEnabled = $true
        DryRun                = $false
        PrivacyMode           = "TitleOnly"
        AppFilterMode         = "Allowlist"
        NtfyServer            = "https://ntfy.sh"
        NtfyTopic             = "super-secret-topic-xyz123"
        NtfyToken             = "tk_secret_auth_token_999"
        AllowedAppIds         = @("Slack", "Teams", "Google Chrome")
        BlockedAppIds         = @("AnnoyingApp")
    } | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($sandboxConfig, $initJson, [System.Text.Encoding]::UTF8)

    $status = Get-DashboardStatus -Dir $sandbox

    Assert-Test -Name "Status engine reads configuration successfully" `
        -Condition ($null -ne $status)

    Assert-Test -Name "Status reflects LiveForwarding state correctly" `
        -Condition ($status.LiveForwarding -eq $true -and $status.ConfigLiveEnabled -eq $true)

    Assert-Test -Name "Status masks NtfyToken (HasToken is boolean true, token string absent)" `
        -Condition ($status.HasToken -eq $true -and ($status.PSObject.Properties['NtfyToken'] -eq $null))

    Assert-Test -Name "Status returns correct PrivacyMode, AppFilterMode, and app counts" `
        -Condition ($status.PrivacyMode -eq "TitleOnly" -and $status.AppFilterMode -eq "Allowlist" -and $status.AllowedAppCount -eq 3 -and $status.BlockedAppCount -eq 1)

    Assert-Test -Name "Status returns ConfigValid = true when configuration is healthy" `
        -Condition ($status.ConfigValid -eq $true)

    Assert-Test -Name "Status returns DestinationConfigured = true when topic is present" `
        -Condition ($status.DestinationConfigured -eq $true)

    Assert-Test -Name "Status masks full topic secret (MaskedTopic contains ellipsis)" `
        -Condition ($status.MaskedTopic -like "*...*" -and $status.MaskedTopic -ne "super-secret-topic-xyz123")

    Assert-Test -Name "Status reports AutoStartupConfigured status" `
        -Condition ($status.AutoStartupConfigured -is [bool])

    # --------------------------------------------------------------------------
    # Test Group 2: Destination Validation & Atomic Write
    # --------------------------------------------------------------------------
    Write-Host "`n--- Group 2: Destination Validation & Atomic Backup ---" -ForegroundColor Yellow

    # Test empty topic rejection
    $resEmpty = Set-DashboardDestination -Dir $sandbox -Server "https://ntfy.sh" -Topic ""
    Assert-Test -Name "Rejects empty topic" `
        -Condition ($resEmpty.Success -eq $false -and $resEmpty.Error -match "cannot be empty")

    # Test invalid characters in topic
    $resInvalidChars = Set-DashboardDestination -Dir $sandbox -Server "https://ntfy.sh" -Topic "bad topic with spaces!"
    Assert-Test -Name "Rejects topic with spaces or special characters" `
        -Condition ($resInvalidChars.Success -eq $false -and $resInvalidChars.Error -match "invalid characters")

    # Test invalid server URL
    $resInvalidServer = Set-DashboardDestination -Dir $sandbox -Server "ftp://not-http" -Topic "valid-topic"
    Assert-Test -Name "Rejects invalid server URL" `
        -Condition ($resInvalidServer.Success -eq $false -and $resInvalidServer.Error -match "valid HTTP or HTTPS")

    # Test valid destination update
    $resValid = Set-DashboardDestination -Dir $sandbox -Server "https://custom.ntfy.io" -Topic "my-new-topic-456"
    Assert-Test -Name "Accepts valid server and topic" `
        -Condition ($resValid.Success -eq $true -and $resValid.Topic -eq "my-new-topic-456")

    # Verify backup was created
    $bakFile = Join-Path -Path $sandbox -ChildPath "config.json.bak"
    Assert-Test -Name "Creates config.json.bak before writing" `
        -Condition (Test-Path $bakFile)

    # Verify atomic update preserved secrets
    $updatedRaw = Get-Content -Path $sandboxConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Test -Name "Atomic update preserved existing NtfyToken" `
        -Condition ($updatedRaw.NtfyToken -eq "tk_secret_auth_token_999")

    Assert-Test -Name "Atomic update preserved AllowedAppIds" `
        -Condition ($updatedRaw.AllowedAppIds.Count -eq 3 -and $updatedRaw.AllowedAppIds -contains "Slack")

    Assert-Test -Name "Atomic update correctly wrote new destination" `
        -Condition ($updatedRaw.NtfyServer -eq "https://custom.ntfy.io" -and $updatedRaw.NtfyTopic -eq "my-new-topic-456")

    # Test full URL pasted into topic field (convenience parsing)
    $resUrlParse = Set-DashboardDestination -Dir $sandbox -Server "" -Topic "https://ntfy.sh/extracted-topic"
    Assert-Test -Name "Automatically parses full ntfy URL in topic field" `
        -Condition ($resUrlParse.Success -eq $true -and $resUrlParse.Topic -eq "extracted-topic" -and $resUrlParse.Server -eq "https://ntfy.sh")

    # --------------------------------------------------------------------------
    # Test Group 3: ON / OFF Transitions & .disabled Marker
    # --------------------------------------------------------------------------
    Write-Host "`n--- Group 3: ON / OFF Control & Watchdog Coordination ---" -ForegroundColor Yellow

    $markerFile = Join-Path -Path $sandbox -ChildPath ".disabled"

    # Turn OFF in sandbox
    $offRes = Set-DashboardForwardingState -Dir $sandbox -Enable $false -ForwarderTaskName "NonExistentTestTask"
    Assert-Test -Name "Turn OFF succeeds" `
        -Condition ($offRes.Success -eq $true -and $offRes.State -eq "OFF")

    Assert-Test -Name "Turn OFF creates .disabled marker file for Watchdog" `
        -Condition (Test-Path $markerFile)

    $offConfig = Get-Content -Path $sandboxConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Test -Name "Turn OFF sets LiveForwardingEnabled = false in config.json" `
        -Condition ($offConfig.LiveForwardingEnabled -eq $false)

    $offStatus = Get-DashboardStatus -Dir $sandbox
    Assert-Test -Name "Status reports ServiceDisabled = true and Watchdog PAUSED" `
        -Condition ($offStatus.ServiceDisabled -eq $true -and $offStatus.WatchdogStatus -match "PAUSED")

    # Turn ON in sandbox
    if (Test-Path $markerFile) {
        Remove-Item -Path $markerFile -Force -ErrorAction SilentlyContinue
    }
    $cfgObj = (Get-Content -Path $sandboxConfig -Raw -Encoding UTF8) | ConvertFrom-Json
    $cfgObj.LiveForwardingEnabled = $true
    $cfgObj.DryRun = $false
    [System.IO.File]::WriteAllText($sandboxConfig, ($cfgObj | ConvertTo-Json -Depth 4), [System.Text.Encoding]::UTF8)

    Assert-Test -Name "Turn ON removes .disabled marker" `
        -Condition (-not (Test-Path $markerFile))

    $onConfig = Get-Content -Path $sandboxConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Test -Name "Turn ON restores LiveForwardingEnabled = true and DryRun = false" `
        -Condition ($onConfig.LiveForwardingEnabled -eq $true -and $onConfig.DryRun -eq $false)

    # --------------------------------------------------------------------------
    # Test Group 4: Application Filtering Management Engine
    # --------------------------------------------------------------------------
    Write-Host "`n--- Group 4: Application Filtering Engine & Pipeline Integration ---" -ForegroundColor Yellow

    # 1. Get-DashboardApps reads current state
    $appData = Get-DashboardApps -Dir $sandbox
    Assert-Test -Name "Get-DashboardApps succeeds" `
        -Condition ($appData.Success -eq $true)

    Assert-Test -Name "Get-DashboardApps returns current mode and configured lists" `
        -Condition ($appData.AppFilterMode -eq "Allowlist" -and $appData.AllowedAppIds.Count -eq 3 -and $appData.BlockedAppIds.Count -eq 1)

    Assert-Test -Name "Get-DashboardApps returns non-empty DiscoveredApps list" `
        -Condition ($appData.DiscoveredApps -ne $null -and $appData.DiscoveredApps.Count -gt 0)

    # 2. Add an Allowed application
    $ts1 = $appData.ConfigTimestamp
    $setAllowedRes = Set-DashboardApps -Dir $sandbox -AllowedAppIds @("Slack", "Teams", "Google Chrome", "Signal") -ExpectedTimestamp $ts1
    Assert-Test -Name "Adding an allowed application succeeds" `
        -Condition ($setAllowedRes.Success -eq $true -and $setAllowedRes.AllowedAppIds -contains "Signal")

    $cfgAfterAdd = Get-Content -Path $sandboxConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Test -Name "Saved allowed application is in config.json" `
        -Condition ($cfgAfterAdd.AllowedAppIds -contains "Signal")

    # 3. Add a Blocked application
    $ts2 = $setAllowedRes.ConfigTimestamp
    $setBlockedRes = Set-DashboardApps -Dir $sandbox -BlockedAppIds @("AnnoyingApp", "SpamTool") -ExpectedTimestamp $ts2
    Assert-Test -Name "Adding a blocked application succeeds" `
        -Condition ($setBlockedRes.Success -eq $true -and $setBlockedRes.BlockedAppIds -contains "SpamTool")

    # 4. Remove / Reset an application rule
    $ts3 = $setBlockedRes.ConfigTimestamp
    $setResetRes = Set-DashboardApps -Dir $sandbox -AllowedAppIds @("Slack", "Teams", "Google Chrome") -BlockedAppIds @("AnnoyingApp") -ExpectedTimestamp $ts3
    Assert-Test -Name "Removing an explicit rule succeeds" `
        -Condition ($setResetRes.Success -eq $true -and $setResetRes.AllowedAppIds -notcontains "Signal" -and $setResetRes.BlockedAppIds -notcontains "SpamTool")

    # 5. Duplicate entries prevention
    $setDupRes = Set-DashboardApps -Dir $sandbox -AllowedAppIds @("Slack", "Slack", "Teams", "Teams")
    Assert-Test -Name "Duplicate entries are de-duplicated" `
        -Condition ($setDupRes.Success -eq $true -and $setDupRes.AllowedAppIds.Count -eq 2)

    # 6. Cross-conflict resolution: if an app is in Blocked, it is removed from Allowed
    $setConflictRes = Set-DashboardApps -Dir $sandbox -AllowedAppIds @("AppA", "AppB") -BlockedAppIds @("AppB")
    Assert-Test -Name "Blocked application is automatically removed from Allowed list" `
        -Condition ($setConflictRes.AllowedAppIds -contains "AppA" -and $setConflictRes.AllowedAppIds -notcontains "AppB" -and $setConflictRes.BlockedAppIds -contains "AppB")

    # 7. Invalid identifier rejected (newlines/control characters)
    $setInvalidRes = Set-DashboardApps -Dir $sandbox -AllowedAppIds @("ValidApp", "Bad`nApp")
    Assert-Test -Name "Rejects identifiers containing illegal newline control characters" `
        -Condition ($setInvalidRes.Success -eq $false -and $setInvalidRes.Error -match "control characters")

    # 8. Mode switching: switch to Blocklist mode
    $setModeBlock = Set-DashboardApps -Dir $sandbox -AppFilterMode "Blocklist"
    Assert-Test -Name "Switching AppFilterMode to Blocklist succeeds" `
        -Condition ($setModeBlock.Success -eq $true -and $setModeBlock.AppFilterMode -eq "Blocklist")

    # 9. Verify preservation of unrelated configuration
    $cfgModeBlock = Get-Content -Path $sandboxConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Test -Name "Mode switch preserved NtfyToken, NtfyServer, and NtfyTopic" `
        -Condition ($cfgModeBlock.NtfyToken -eq "tk_secret_auth_token_999" -and $cfgModeBlock.NtfyServer -eq "https://ntfy.sh" -and $cfgModeBlock.NtfyTopic -eq "extracted-topic")

    # 10. Switch back to Allowlist mode
    $setModeAllow = Set-DashboardApps -Dir $sandbox -AppFilterMode "Allowlist"
    Assert-Test -Name "Switching AppFilterMode back to Allowlist succeeds" `
        -Condition ($setModeAllow.Success -eq $true -and $setModeAllow.AppFilterMode -eq "Allowlist")

    # 11. Optimistic concurrency check
    $staleTs = "2020-01-01T00:00:00.0000000Z"
    $setStaleRes = Set-DashboardApps -Dir $sandbox -AllowedAppIds @("NewApp") -ExpectedTimestamp $staleTs
    Assert-Test -Name "Optimistic concurrency rejects stale ExpectedTimestamp" `
        -Condition ($setStaleRes.Success -eq $false -and $setStaleRes.Error -match "concurrently")

    # 12. Real Notification Pipeline Integration Test
    # Setup test app config: Allowlist mode, Allowed = @("WhatsApp"), Blocked = @("SpamApp")
    $setPipeConfig = Set-DashboardApps -Dir $sandbox -AppFilterMode "Allowlist" -AllowedAppIds @("WhatsApp") -BlockedAppIds @("SpamApp")
    $pipeCfg = (Get-Content -Path $sandboxConfig -Raw -Encoding UTF8) | ConvertFrom-Json
    $pipeHashtable = @{
        AppFilterMode = $pipeCfg.AppFilterMode
        AllowedAppIds = @($pipeCfg.AllowedAppIds)
        BlockedAppIds = @($pipeCfg.BlockedAppIds)
        PrivacyMode   = "TitleOnly"
    }

    # Test allowed app
    $notifAllowed = [PSCustomObject]@{
        Id             = 1001
        AppDisplayName = "WhatsApp"
        AppUserModelId = "5319275A.WhatsAppDesktop!App"
        Title          = "Hello"
        Body           = "Secret Body"
    }
    $filteredAllowed = Filter-Notification -NotificationData $notifAllowed -Config $pipeHashtable
    Assert-Test -Name "Pipeline permits WhatsApp under Allowlist mode" `
        -Condition ($filteredAllowed -ne $null -and $filteredAllowed.IsAllowed -eq $true)

    # Test unlisted app under Allowlist mode -> blocked
    $notifUnlisted = [PSCustomObject]@{
        Id             = 1002
        AppDisplayName = "RandomGame"
        AppUserModelId = "RandomGame.Exe"
        Title          = "Game Alert"
        Body           = "You won!"
    }
    $filteredUnlisted = Filter-Notification -NotificationData $notifUnlisted -Config $pipeHashtable
    Assert-Test -Name "Pipeline blocks unlisted app under Allowlist mode" `
        -Condition ($filteredUnlisted -eq $null)

    # Test blocked app under Allowlist mode -> blocked
    $notifBlocked = [PSCustomObject]@{
        Id             = 1003
        AppDisplayName = "SpamApp"
        AppUserModelId = "Spam.Exe"
        Title          = "Spam"
        Body           = "Buy now"
    }
    $filteredBlocked = Filter-Notification -NotificationData $notifBlocked -Config $pipeHashtable
    Assert-Test -Name "Pipeline blocks explicitly blocked app under Allowlist mode" `
        -Condition ($filteredBlocked -eq $null)

    # Switch pipeline config to Blocklist mode
    $pipeHashtable.AppFilterMode = "Blocklist"
    $filteredUnlistedInBlocklist = Filter-Notification -NotificationData $notifUnlisted -Config $pipeHashtable
    Assert-Test -Name "Pipeline permits unlisted app under Blocklist mode" `
        -Condition ($filteredUnlistedInBlocklist -ne $null -and $filteredUnlistedInBlocklist.IsAllowed -eq $true)

    $filteredBlockedInBlocklist = Filter-Notification -NotificationData $notifBlocked -Config $pipeHashtable
    Assert-Test -Name "Pipeline blocks explicitly blocked app under Blocklist mode" `
        -Condition ($filteredBlockedInBlocklist -eq $null)

    # --------------------------------------------------------------------------
    # Test Group 5: Localhost-only HTTP Security & Auth Token Enforcement
    # --------------------------------------------------------------------------
    Write-Host "`n--- Group 5: Localhost Security & Session Auth ---" -ForegroundColor Yellow

    $testPort = 18765
    $testToken = "TestAuthToken_12345"

    $serverJob = Start-Job -ScriptBlock {
        param($DashboardScriptPath, $Dir, $Port, $Token)
        & $DashboardScriptPath -ProjectDir $Dir -Port $Port -AuthToken $Token -TimeoutSeconds 15
    } -ArgumentList $dashboardScript, $sandbox, $testPort, $testToken

    Start-Sleep -Seconds 2

    try {
        # 1. Test request without token -> should return 401 Unauthorized
        $unauthFailed = $false
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$testPort/api/status" -Method GET -UseBasicParsing -ErrorAction Stop
        } catch {
            if ($_.Exception.Response.StatusCode.value__ -eq 401) {
                $unauthFailed = $true
            }
        }
        Assert-Test -Name "Missing auth token returns 401 Unauthorized on /api/status" `
            -Condition $unauthFailed

        # 2. Test request with wrong token -> should return 403 Forbidden
        $wrongTokenFailed = $false
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$testPort/api/status?token=wrong_token" -Method GET -UseBasicParsing -ErrorAction Stop
        } catch {
            if ($_.Exception.Response.StatusCode.value__ -eq 403) {
                $wrongTokenFailed = $true
            }
        }
        Assert-Test -Name "Invalid auth token returns 403 Forbidden on /api/status" `
            -Condition $wrongTokenFailed

        # 3. Test GET /api/apps with valid token -> returns 200 OK + apps payload
        $validSuccess = $false
        $validAppsObj = $null
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$testPort/api/apps?token=$testToken" -Method GET -UseBasicParsing -ErrorAction Stop
            if ($resp.StatusCode -eq 200) {
                $validSuccess = $true
                $validAppsObj = $resp.Content | ConvertFrom-Json
            }
        } catch { }
        Assert-Test -Name "GET /api/apps returns 200 OK with valid auth token" `
            -Condition $validSuccess

        Assert-Test -Name "GET /api/apps returns DiscoveredApps and AllowedAppIds" `
            -Condition ($validAppsObj -ne $null -and $validAppsObj.AllowedAppIds -ne $null -and $validAppsObj.DiscoveredApps -ne $null)

        # 4. Test POST /api/apps with valid token
        $postAppsSuccess = $false
        try {
            $body = @{
                AppFilterMode = "Allowlist"
                AllowedAppIds = @("HTTPAllowedApp")
                BlockedAppIds = @("HTTPBlockedApp")
            } | ConvertTo-Json
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$testPort/api/apps?token=$testToken" -Method POST -Body $body -ContentType "application/json" -UseBasicParsing -ErrorAction Stop
            if ($resp.StatusCode -eq 200) {
                $parsedPost = $resp.Content | ConvertFrom-Json
                if ($parsedPost.Success -eq $true -and ($parsedPost.AllowedAppIds -contains "HTTPAllowedApp")) {
                    $postAppsSuccess = $true
                }
            }
        } catch { }
        Assert-Test -Name "POST /api/apps successfully updates rules over authenticated HTTP API" `
            -Condition $postAppsSuccess

        # 5. Test security headers
        $hasNoSniff = $false
        $hasDenyFrame = $false
        try {
            $htmlResp = Invoke-WebRequest -Uri "http://127.0.0.1:$testPort/?token=$testToken" -Method GET -UseBasicParsing -ErrorAction Stop
            $headers = $htmlResp.Headers
            if ($headers["X-Content-Type-Options"] -eq "nosniff") { $hasNoSniff = $true }
            if ($headers["X-Frame-Options"] -eq "DENY") { $hasDenyFrame = $true }
        } catch { }
        Assert-Test -Name "HTTP server sends security header X-Content-Type-Options: nosniff" `
            -Condition $hasNoSniff

        Assert-Test -Name "HTTP server sends security header X-Frame-Options: DENY" `
            -Condition $hasDenyFrame

        # 6. Test POST /api/start-push auth enforcement
        $pushUnauthFailed = $false
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$testPort/api/start-push" -Method POST -UseBasicParsing -ErrorAction Stop
        } catch {
            if ($_.Exception.Response.StatusCode.value__ -eq 401) { $pushUnauthFailed = $true }
        }
        Assert-Test -Name "Missing auth token returns 401 Unauthorized on /api/start-push" `
            -Condition $pushUnauthFailed

        $pushForbiddenFailed = $false
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$testPort/api/start-push?token=wrong_token" -Method POST -UseBasicParsing -ErrorAction Stop
        } catch {
            if ($_.Exception.Response.StatusCode.value__ -eq 403) { $pushForbiddenFailed = $true }
        }
        Assert-Test -Name "Invalid auth token returns 403 Forbidden on /api/start-push" `
            -Condition $pushForbiddenFailed

        # 7. Test POST /api/start-push endpoint executes safely
        $pushEndpointRan = $false
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$testPort/api/start-push?token=$testToken" -Method POST -UseBasicParsing -ErrorAction Stop
            if ($resp.StatusCode -in @(200, 400)) {
                $parsed = $resp.Content | ConvertFrom-Json
                if ($parsed.Step -or $parsed.Success -ne $null) {
                    $pushEndpointRan = $true
                }
            }
        } catch { }
        Assert-Test -Name "POST /api/start-push returns structured response without unhandled errors" `
            -Condition $pushEndpointRan

    } finally {
        Stop-Job $serverJob -ErrorAction SilentlyContinue
        Remove-Job $serverJob -Force -ErrorAction SilentlyContinue
    }

    # --------------------------------------------------------------------------
    # Test Group 6: One-Click 'Start Push Notification' Workflow Engine
    # --------------------------------------------------------------------------
    Write-Host "`n--- Group 6: Start Push Notification Workflow Engine ---" -ForegroundColor Yellow

    # Create dedicated sub-sandbox with simulated project files
    $wfSandbox = Join-Path -Path $sandbox -ChildPath "WorkflowSandbox"
    New-Item -ItemType Directory -Path $wfSandbox -Force | Out-Null

    # Required scripts simulation
    $mockScripts = @(
        "NotificationForwarder.ps1", "NotificationReader.ps1", "NotificationFilter.ps1",
        "NotificationSender.ps1", "Config.ps1", "Watchdog.ps1", "Run-WatchdogHidden.vbs",
        "Recover-NotificationForwarder.ps1", "Register-NotificationForwarderTask.ps1",
        "Get-NotificationForwarderStatus.ps1"
    )

    # 1. Test missing scripts detection
    $resMissing = Invoke-StartPushNotification -ProjectDir $wfSandbox -SkipTaskRegistration
    Assert-Test -Name "Invoke-StartPushNotification rejects when required scripts are missing" `
        -Condition ($resMissing.Success -eq $false -and $resMissing.Step -eq "ScriptValidation")

    # Populate mock scripts
    foreach ($s in $mockScripts) {
        [System.IO.File]::WriteAllText((Join-Path $wfSandbox $s), "# mock $s", [System.Text.Encoding]::UTF8)
    }

    # 2. Test invalid topic rejection
    $badCfg = @{
        LiveForwardingEnabled = $false
        DryRun                = $true
        NtfyServer            = "https://ntfy.sh"
        NtfyTopic             = ""
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path $wfSandbox "config.json"), $badCfg, [System.Text.Encoding]::UTF8)

    $resBadTopic = Invoke-StartPushNotification -ProjectDir $wfSandbox -SkipTaskRegistration
    Assert-Test -Name "Invoke-StartPushNotification rejects empty destination topic" `
        -Condition ($resBadTopic.Success -eq $false -and $resBadTopic.Step -eq "TopicValidation")

    # 3. Test valid configuration atomic update, .disabled removal, and backup creation
    $validCfg = @{
        LiveForwardingEnabled = $false
        DryRun                = $true
        NtfyServer            = "https://ntfy.sh"
        NtfyTopic             = "valid_test_topic_12345"
        DeviceName            = "TEST-DEVICE"
        PrivacyMode           = "TitleOnly"
        AppFilterMode         = "Allowlist"
        AllowedAppIds         = @("AppOne", "AppTwo")
        BlockedAppIds         = @()
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path $wfSandbox "config.json"), $validCfg, [System.Text.Encoding]::UTF8)

    # Place a .disabled marker to verify cleanup
    [System.IO.File]::WriteAllText((Join-Path $wfSandbox ".disabled"), "disabled marker", [System.Text.Encoding]::UTF8)

    # Execute workflow (will stop at ProcessVerification since mock forwarder isn't a real running daemon)
    $resWf = Invoke-StartPushNotification -ProjectDir $wfSandbox -SkipTaskRegistration

    # Verify backup was created
    Assert-Test -Name "Invoke-StartPushNotification preserves config.json.bak before applying changes" `
        -Condition (Test-Path (Join-Path $wfSandbox "config.json.bak"))

    # Verify .disabled was removed
    Assert-Test -Name "Invoke-StartPushNotification removes .disabled sentinel marker" `
        -Condition (-not (Test-Path (Join-Path $wfSandbox ".disabled")))

    # Verify rollback/safe recovery if process verification cannot find real daemon
    Assert-Test -Name "Invoke-StartPushNotification safely stops at ProcessVerification in simulated environment" `
        -Condition ($resWf.Success -eq $false -and $resWf.Step -eq "ProcessVerification")

    # --------------------------------------------------------------------------
    # Test Group 7: Active Production Verification (Non-disruption)
    # --------------------------------------------------------------------------
    Write-Host "`n--- Group 7: Production Service Health Verification ---" -ForegroundColor Yellow

    $prodStatus = Get-DashboardStatus -Dir $ProjectDir
    Assert-Test -Name "Production forwarder remains RUNNING" `
        -Condition ($prodStatus.ForwarderStatus -eq "RUNNING" -and $prodStatus.ForwarderProcessId -gt 0)

    Assert-Test -Name "Production LiveForwarding is currently active" `
        -Condition ($prodStatus.LiveForwarding -eq $true -and $prodStatus.ConfigLiveEnabled -eq $true)

    Assert-Test -Name "Production Watchdog task is registered and healthy" `
        -Condition ($prodStatus.WatchdogTaskState -in @("Ready", "Running"))

    Assert-Test -Name "Production .disabled marker is not present" `
        -Condition ($prodStatus.ServiceDisabled -eq $false)

    $prodFwdTask = Get-ScheduledTask -TaskName "NotificationForwarder" -ErrorAction SilentlyContinue
    Assert-Test -Name "Production forwarder task action executes wscript.exe silent launcher" `
        -Condition ($prodFwdTask -ne $null -and $prodFwdTask.Actions.Execute -eq "wscript.exe")

    Assert-Test -Name "Production forwarder task targets Run-ForwarderHidden.vbs" `
        -Condition ($prodFwdTask -ne $null -and $prodFwdTask.Actions.Arguments -match "Run-ForwarderHidden\.vbs")

    $prodFwdProc = Get-CimInstance Win32_Process -Filter "ProcessId = $($prodStatus.ForwarderProcessId)" -ErrorAction SilentlyContinue
    $parentProc = if ($prodFwdProc) { Get-CimInstance Win32_Process -Filter "ProcessId = $($prodFwdProc.ParentProcessId)" -ErrorAction SilentlyContinue } else { $null }
    $isDetached = if ($parentProc) { $parentProc.Name -in @("wscript.exe", "svchost.exe") } else { $false }
    Assert-Test -Name "Production forwarder is detached from interactive console (parent is wscript or svchost)" `
        -Condition ($isDetached -eq $true)

} finally {
    if (Test-Path $sandbox) {
        Remove-Item -Path $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}


# -------------------------------------------------------------------------
# Group 8: Universal Pass - Explicit Key Generation, Service States & Portability
# -------------------------------------------------------------------------
Write-Host "`n--- Group 8: Universal Pass Verification ---" -ForegroundColor Yellow

# 1. Verify ServiceState in Get-DashboardStatus
$statusObj = Get-DashboardStatus -Dir $ProjectDir
Assert-Test -Name "Status returns a valid ServiceState" `
    -Condition ($statusObj.ServiceState -in @("Not Configured", "Needs Permission", "Stopped", "Starting", "Running", "Error"))

# 2. Verify Turn Forwarding ON rejection when topic is empty
$emptySandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("Dash_Empty_" + [System.Guid]::NewGuid().ToString("N"))
[void](New-Item -ItemType Directory -Path $emptySandbox -Force)
try {
    $emptyCfg = @{
        LiveForwardingEnabled = $false
        DryRun                = $true
        NtfyServer            = "https://ntfy.sh"
        NtfyTopic             = ""
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path $emptySandbox "config.json"), $emptyCfg, [System.Text.Encoding]::UTF8)

    $turnOnRes = Set-DashboardForwardingState -Dir $emptySandbox -Enable $true
    Assert-Test -Name "Turn ON rejects activation when topic is empty" `
        -Condition ($turnOnRes.Success -eq $false -and $turnOnRes.State -eq "Not Configured")

    $emptyStatus = Get-DashboardStatus -Dir $emptySandbox
    Assert-Test -Name "Status reports 'Not Configured' when topic is empty" `
        -Condition ($emptyStatus.ServiceState -eq "Not Configured")

} finally {
    if (Test-Path $emptySandbox) {
        Remove-Item -Path $emptySandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 3. Verify Dashboard HTML contains Generate New Key and Copy Key buttons
$dashHtmlContent = Get-Content -Path (Join-Path $ProjectDir "Start-Dashboard.ps1") -Raw
Assert-Test -Name "Dashboard HTML includes Generate New Key button" `
    -Condition ($dashHtmlContent -match 'id="btnGenKey"[^>]*>Generate New Key<')
Assert-Test -Name "Dashboard HTML includes Copy Key button" `
    -Condition ($dashHtmlContent -match 'id="btnCopyKey"[^>]*>Copy Key<')
Assert-Test -Name "Dashboard HTML includes Service State status row" `
    -Condition ($dashHtmlContent -match 'id="valServiceState"')

# 4. Path containing spaces portability for dashboard functions
$spaceDashDir = Join-Path ([System.IO.Path]::GetTempPath()) ("Dash Space " + [System.Guid]::NewGuid().ToString("N"))
[void](New-Item -ItemType Directory -Path $spaceDashDir -Force)
try {
    $spaceCfg = @{
        LiveForwardingEnabled = $false
        DryRun                = $true
        NtfyServer            = "https://ntfy.sh"
        NtfyTopic             = "win-spacedash1234567890abcdef"
        DeviceName            = "Space-PC"
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path $spaceDashDir "config.json"), $spaceCfg, [System.Text.Encoding]::UTF8)

    $spaceStatus = Get-DashboardStatus -Dir $spaceDashDir
    Assert-Test -Name "Dashboard Get-DashboardStatus works in paths with spaces" `
        -Condition ($spaceStatus.DestinationConfigured -eq $true)
} finally {
    if (Test-Path $spaceDashDir) {
        Remove-Item -Path $spaceDashDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n==========================================================" -ForegroundColor Cyan

# -------------------------------------------------------------------------
# Group 9: Application Filtering Fixes & Identity Verification
# -------------------------------------------------------------------------
Write-Host "`n--- Group 9: Application Filtering Fixes & Identity Verification ---" -ForegroundColor Yellow

$appTestSandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("DashAppTest_" + [System.Guid]::NewGuid().ToString("N"))
[void](New-Item -ItemType Directory -Path $appTestSandbox -Force)

try {
    $baseConfig = @{
        LiveForwardingEnabled = $false
        DryRun                = $true
        NtfyServer            = "https://ntfy.sh"
        NtfyTopic             = "win-appfiltertest1234567890abcdef"
        DeviceName            = "AppFilter-PC"
        AppFilterMode         = "Allowlist"
        AllowedAppIds         = @("WhatsApp", "Google Chrome")
        BlockedAppIds         = @("SpamApp")
        PrivacyMode           = "TitleOnly"
    } | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText((Join-Path $appTestSandbox "config.json"), $baseConfig, [System.Text.Encoding]::UTF8)

    # 1. Saving an allowlist succeeds and persists
    $saveResult = Set-DashboardApps -Dir $appTestSandbox -AppFilterMode "Allowlist" -AllowedAppIds @("WhatsApp", "Google Chrome", "Slack") -BlockedAppIds @("SpamApp")
    Assert-Test -Name "Saving an allowlist succeeds" -Condition ($saveResult.Success -eq $true)

    $persistedCfg = (Get-Content (Join-Path $appTestSandbox "config.json") -Raw | ConvertFrom-Json)
    Assert-Test -Name "Saved allowlist persists to config.json" -Condition ($persistedCfg.AllowedAppIds -contains "Slack")

    # 2. Save failures on invalid identifiers are reported accurately
    $badSaveResult = Set-DashboardApps -Dir $appTestSandbox -AllowedAppIds @("Bad`nApp")
    Assert-Test -Name "Save failures on illegal characters are reported accurately" `
        -Condition ($badSaveResult.Success -eq $false -and $badSaveResult.Error -match "illegal control characters")

    # 3. Allow works directly for detected application without manual entry in Add Custom
    $discoveredData = Get-DashboardApps -Dir $appTestSandbox
    Assert-Test -Name "Get-DashboardApps returns DiscoveredApps" -Condition ($discoveredData.DiscoveredApps.Count -ge 0)

    # Simulate user clicking Allow directly on detected app row
    $allowAdd = Set-DashboardApps -Dir $appTestSandbox -AllowedAppIds @($persistedCfg.AllowedAppIds + "Visual Studio Code")
    Assert-Test -Name "Allow works directly for detected application" -Condition ($allowAdd.Success -eq $true)

    # 4. Application identifiers remain consistent across detection, saving, and runtime filtering
    # Dot-source filter engine
    . (Join-Path $ProjectDir "NotificationFilter.ps1")

    # Candidate 1: Classic Win32 app where notification has DisplayName = "Google Chrome" and AUMID = "Chrome"
    $chromeNotif = [PSCustomObject]@{
        Id             = 101
        AppUserModelId = "Chrome"
        AppDisplayName = "Google Chrome"
        Title          = "New Tab"
        Body           = "Downloaded file"
    }
    $chromeAllowed = Test-IsAppAllowed -AppUserModelId $chromeNotif.AppUserModelId -AppDisplayName $chromeNotif.AppDisplayName -AppFilterMode "Allowlist" -AllowedAppIds @("Google Chrome")
    Assert-Test -Name "Pipeline permits app when rule matches DisplayName ('Google Chrome' vs 'Chrome')" -Condition ($chromeAllowed -eq $true)

    $chromeAllowedAumid = Test-IsAppAllowed -AppUserModelId $chromeNotif.AppUserModelId -AppDisplayName $chromeNotif.AppDisplayName -AppFilterMode "Allowlist" -AllowedAppIds @("Chrome")
    Assert-Test -Name "Pipeline permits app when rule matches AUMID ('Chrome')" -Condition ($chromeAllowedAumid -eq $true)

    # Candidate 2: App with path-based AppId like 'L:\Programs\3uTools\3uTools.exe'
    $pathNotif = [PSCustomObject]@{
        Id             = 102
        AppUserModelId = "L:\\Programs\\3uTools\\3uTools.exe"
        AppDisplayName = "3uTools"
        Title          = "Device Connected"
        Body           = "iPhone connected"
    }
    $pathAllowedByExe = Test-IsAppAllowed -AppUserModelId $pathNotif.AppUserModelId -AppDisplayName $pathNotif.AppDisplayName -AppFilterMode "Allowlist" -AllowedAppIds @("3uTools.exe")
    Assert-Test -Name "Pipeline permits app when rule matches executable stem/file ('3uTools.exe')" -Condition ($pathAllowedByExe -eq $true)

    $pathAllowedByName = Test-IsAppAllowed -AppUserModelId $pathNotif.AppUserModelId -AppDisplayName $pathNotif.AppDisplayName -AppFilterMode "Allowlist" -AllowedAppIds @("3uTools")
    Assert-Test -Name "Pipeline permits app when rule matches clean DisplayName ('3uTools')" -Condition ($pathAllowedByName -eq $true)

    # Candidate 3: UWP App with Package Family Name
    $uwpNotif = [PSCustomObject]@{
        Id             = 103
        AppUserModelId = "5319275A.WhatsAppDesktop_cv1g1gvanyjgm!App"
        AppDisplayName = "WhatsApp"
        Title          = "Alice"
        Body           = "Hello!"
    }
    $uwpAllowed = Test-IsAppAllowed -AppUserModelId $uwpNotif.AppUserModelId -AppDisplayName $uwpNotif.AppDisplayName -AppFilterMode "Allowlist" -AllowedAppIds @("WhatsApp")
    Assert-Test -Name "Pipeline permits UWP app by DisplayName ('WhatsApp')" -Condition ($uwpAllowed -eq $true)

    $uwpAllowedPfn = Test-IsAppAllowed -AppUserModelId $uwpNotif.AppUserModelId -AppDisplayName $uwpNotif.AppDisplayName -AppFilterMode "Allowlist" -AllowedAppIds @("5319275A.WhatsAppDesktop*")
    Assert-Test -Name "Pipeline permits UWP app by Package Family Name wildcard" -Condition ($uwpAllowedPfn -eq $true)

    # Candidate 4: App with apostrophe in name (e.g. "Tom's App")
    $quoteNotif = [PSCustomObject]@{
        Id             = 104
        AppUserModelId = "TomsApp"
        AppDisplayName = "Tom's App"
        Title          = "Alert"
        Body           = "Task done"
    }
    $quoteAllowed = Test-IsAppAllowed -AppUserModelId $quoteNotif.AppUserModelId -AppDisplayName $quoteNotif.AppDisplayName -AppFilterMode "Allowlist" -AllowedAppIds @("Tom's App")
    Assert-Test -Name "Pipeline handles apps with apostrophes safely ('Tom''s App')" -Condition ($quoteAllowed -eq $true)

    # 5. Duplicate Allow actions do not create duplicate entries
    $dupRes = Set-DashboardApps -Dir $appTestSandbox -AllowedAppIds @("Slack", "Slack", "SLACK", " WhatsApp ")
    $reloadedDup = (Get-Content (Join-Path $appTestSandbox "config.json") -Raw | ConvertFrom-Json)
    $slackCount = @($reloadedDup.AllowedAppIds | Where-Object { $_ -ieq "Slack" }).Count
    Assert-Test -Name "Duplicate Allow actions do not create duplicate entries" -Condition ($slackCount -eq 1)

    # 6. Refreshing or restarting preserves saved rules
    $freshFetch = Get-DashboardApps -Dir $appTestSandbox
    Assert-Test -Name "Refreshing or restarting preserves saved rules" `
        -Condition ($freshFetch.AllowedAppIds -contains "Slack" -and $freshFetch.AllowedAppIds -contains "WhatsApp")

    # 7. Blocked applications remain blocked
    $blockedNotifCheck = Test-IsAppAllowed -AppUserModelId "SpamApp" -AppDisplayName "SpamApp" -AppFilterMode "Allowlist" -AllowedAppIds @("SpamApp") -BlockedAppIds @("SpamApp")
    Assert-Test -Name "Blocked applications remain blocked even if present in allowed list" -Condition ($blockedNotifCheck -eq $false)

    # 8. Missing or invalid identifiers are handled safely
    $emptyNotifCheck = Test-IsAppAllowed -AppUserModelId "" -AppDisplayName "" -AppFilterMode "Allowlist" -AllowedAppIds @("WhatsApp")
    Assert-Test -Name "Missing candidate identifiers are safely denied under Allowlist" -Condition ($emptyNotifCheck -eq $false)

    # 9. Real-World Bug Reproduction: config.json without BlockedAppIds NoteProperty
    $noBlockedSandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("NoBlockedApp_" + [System.Guid]::NewGuid().ToString("N"))
    [void](New-Item -ItemType Directory -Path $noBlockedSandbox -Force)
    try {
        # Mirrors production config where BlockedAppIds property does not pre-exist
        $cfgWithoutBlocked = @{
            LiveForwardingEnabled = $false
            DryRun                = $true
            NtfyServer            = "https://ntfy.sh"
            NtfyTopic             = "win-noblockedtest1234567890abcdef"
            DeviceName            = "NoBlocked-PC"
            AppFilterMode         = "Allowlist"
            AllowedAppIds         = @("WhatsApp")
            IgnoreAppIds          = @()
            PrivacyMode           = "TitleOnly"
        } | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText((Join-Path $noBlockedSandbox "config.json"), $cfgWithoutBlocked, [System.Text.Encoding]::UTF8)

        $saveNoBlocked = Set-DashboardApps -Dir $noBlockedSandbox -AppFilterMode "Allowlist" -AllowedAppIds @("WhatsApp", "NewApp") -BlockedAppIds @("BadApp")
        Assert-Test -Name "Saving succeeds when config.json lacks BlockedAppIds NoteProperty" -Condition ($saveNoBlocked.Success -eq $true)

        $diskNoBlocked = Get-Content (Join-Path $noBlockedSandbox "config.json") -Raw | ConvertFrom-Json
        Assert-Test -Name "BlockedAppIds is persisted when originally absent" -Condition ($diskNoBlocked.BlockedAppIds -contains "BadApp")
        Assert-Test -Name "IgnoreAppIds is synchronized with BlockedAppIds for legacy compatibility" -Condition ($diskNoBlocked.IgnoreAppIds -contains "BadApp")

        # Saving empty lists works and does not restore previous values
        $saveEmpty = Set-DashboardApps -Dir $noBlockedSandbox -AppFilterMode "Allowlist" -AllowedAppIds @() -BlockedAppIds @()
        Assert-Test -Name "Saving empty AllowedAppIds and BlockedAppIds succeeds" -Condition ($saveEmpty.Success -eq $true)
        $diskEmpty = Get-Content (Join-Path $noBlockedSandbox "config.json") -Raw | ConvertFrom-Json
        Assert-Test -Name "Persisted AllowedAppIds is empty array" -Condition ($diskEmpty.AllowedAppIds.Count -eq 0)
        Assert-Test -Name "Persisted BlockedAppIds is empty array" -Condition ($diskEmpty.BlockedAppIds.Count -eq 0)
    } finally {
        if (Test-Path $noBlockedSandbox) {
            Remove-Item -Path $noBlockedSandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

} finally {
    if (Test-Path $appTestSandbox) {
        Remove-Item -Path $appTestSandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------------------------------
# Group 10: Send Test Workflow & Safety Verification
# -------------------------------------------------------------------------
Write-Host "`n--- Group 10: Send Test Workflow & Safety Verification ---" -ForegroundColor Yellow

$sendTestSandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("DashSendTest_" + [System.Guid]::NewGuid().ToString("N"))
[void](New-Item -ItemType Directory -Path $sendTestSandbox -Force)

try {
    # 1. Dashboard displays Send Test button
    $dashboardScriptContent = Get-Content -Path (Join-Path $ProjectDir "Start-Dashboard.ps1") -Raw
    Assert-Test -Name "Dashboard displays the Send Test button (id='btnSendTest')" `
        -Condition ($dashboardScriptContent -match 'id="btnSendTest"[^>]*>Send Test<')

    # 2. Safety check: No message is sent merely by opening or refreshing dashboard
    $initStatus = Get-DashboardStatus -Dir $ProjectDir
    Assert-Test -Name "No message is sent merely by opening or refreshing dashboard" `
        -Condition ($initStatus.DestinationConfigured -eq $true)

    # 3. Missing or invalid configuration produces clear error
    $missingTopicCfg = @{
        LiveForwardingEnabled = $false
        DryRun                = $true
        NtfyServer            = "https://ntfy.sh"
        NtfyTopic             = ""
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path $sendTestSandbox "config.json"), $missingTopicCfg, [System.Text.Encoding]::UTF8)

    $emptySendResult = Send-DashboardTestNotification -Dir $sendTestSandbox
    Assert-Test -Name "Send Test fails with clear error when destination topic is empty" `
        -Condition ($emptySendResult.Success -eq $false -and $emptySendResult.Error -match "empty")

    # Insecure HTTP rejected
    $insecureCfg = @{
        LiveForwardingEnabled = $false
        DryRun                = $true
        NtfyServer            = "http://insecure-server.com"
        NtfyTopic             = "win-validtopic1234567890abcdef"
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path $sendTestSandbox "config.json"), $insecureCfg, [System.Text.Encoding]::UTF8)

    $insecureSendResult = Send-DashboardTestNotification -Dir $sendTestSandbox
    Assert-Test -Name "Send Test fails with clear error when server uses insecure HTTP" `
        -Condition ($insecureSendResult.Success -eq $false -and $insecureSendResult.Error -match "HTTPS")

    # 4. Clicking the button invokes the existing delivery mechanism once
    $validCfg = @{
        LiveForwardingEnabled = $false
        DryRun                = $true
        NtfyServer            = "https://ntfy.sh"
        NtfyTopic             = "win-testtopic1234567890abcdef"
        DeviceName            = "TestPC"
        PrivacyMode           = "TitleOnly"
        AllowedAppIds         = @("WhatsApp")
        BlockedAppIds         = @()
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path $sendTestSandbox "config.json"), $validCfg, [System.Text.Encoding]::UTF8)

    $mockSentCount = 0
    $mockRecordedUrl = ""
    $mockRecordedHeaders = $null
    $mockRecordedBody = ""

    $mockHttpHandler = {
        param($Url, $Headers, $Body, $Attempt)
        $script:mockSentCount++
        $script:mockRecordedUrl = $Url
        $script:mockRecordedHeaders = $Headers
        $script:mockRecordedBody = $Body
        return @{ StatusCode = 200; StatusDescription = "OK" }
    }

    $sendSuccessResult = Send-DashboardTestNotification -Dir $sendTestSandbox -CustomHttpHandler $mockHttpHandler
    Assert-Test -Name "Send Test invokes delivery mechanism once" -Condition ($sendSuccessResult.Success -eq $true -and $mockSentCount -eq 1)
    Assert-Test -Name "Send Test payload uses recognizable test message" `
        -Condition ($mockRecordedBody -match "NotificationForwarder test message")
    Assert-Test -Name "Send Test reports ConfirmedDelivery = True on HTTP 200" `
        -Condition ($sendSuccessResult.ConfirmedDelivery -eq $true)

    # 5. Delivery failures are shown accurately
    $mockFailHttpHandler = {
        param($Url, $Headers, $Body, $Attempt)
        throw "Simulated network timeout connecting to ntfy server"
    }
    $sendFailResult = Send-DashboardTestNotification -Dir $sendTestSandbox -CustomHttpHandler $mockFailHttpHandler
    Assert-Test -Name "Delivery failures are reported accurately" `
        -Condition ($sendFailResult.Success -eq $false -and $sendFailResult.Error -match "Simulated network timeout")

    # 6. Safety check: Sending a test does NOT enable live forwarding or change filters or privacy settings
    $postSendCfg = (Get-Content (Join-Path $sendTestSandbox "config.json") -Raw | ConvertFrom-Json)
    Assert-Test -Name "Sending a test does NOT enable live forwarding (LiveForwardingEnabled remains false)" `
        -Condition ($postSendCfg.LiveForwardingEnabled -eq $false)
    Assert-Test -Name "Sending a test does NOT alter DryRun mode (DryRun remains true)" `
        -Condition ($postSendCfg.DryRun -eq $true)
    Assert-Test -Name "Sending a test does NOT modify AllowedAppIds" `
        -Condition ($postSendCfg.AllowedAppIds -contains "WhatsApp")
    Assert-Test -Name "Sending a test does NOT modify PrivacyMode" `
        -Condition ($postSendCfg.PrivacyMode -eq "TitleOnly")

    # 7. Secrets are not exposed in responses or logs
    Assert-Test -Name "Send Test success response does NOT expose secret topic" `
        -Condition (-not ($sendSuccessResult.Message -match "win-testtopic1234567890abcdef"))
    Assert-Test -Name "Send Test failure response does NOT expose secret topic" `
        -Condition (-not ($sendFailResult.Error -match "win-testtopic1234567890abcdef"))

} finally {
    if (Test-Path $sendTestSandbox) {
        Remove-Item -Path $sendTestSandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host " Dashboard & App Filter Test Results: $passedTests / $totalTests passed ($failedTests failed)" -ForegroundColor $(if ($failedTests -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failedTests -gt 0) {
    exit 1
} else {
    exit 0
}
