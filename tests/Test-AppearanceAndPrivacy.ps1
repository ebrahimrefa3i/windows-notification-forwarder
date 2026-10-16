# ==============================================================================

# Test-AppearanceAndPrivacy.ps1

# Automated Test Suite for Custom Notification Appearance & Dashboard Privacy Controls

# ==============================================================================



[CmdletBinding()]
param(
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



$ErrorActionPreference = "Stop"



# Setup test counters

$Global:PassedCount = 0

$Global:FailedCount = 0

$Global:FailedTests = @()



function Assert-Test {

    param(

        [string]$Name,

        [bool]$Condition,

        [string]$Details = ""

    )



    if ($Condition) {

        Write-Host "  [PASS] $Name" -ForegroundColor Green

        $Global:PassedCount++

    } else {

        Write-Host "  [FAIL] $Name" -ForegroundColor Red

        if ($Details) {

            Write-Host "         Details: $Details" -ForegroundColor Yellow

        }

        $Global:FailedCount++

        $Global:FailedTests += "$Name ($Details)"

    }

}



Write-Host "==========================================================" -ForegroundColor Cyan

Write-Host " Running Notification Appearance & Privacy Controls Suite" -ForegroundColor Cyan

Write-Host "==========================================================" -ForegroundColor Cyan



# Source project dependencies

. (Join-Path $ProjectDir "Config.ps1")

. (Join-Path $ProjectDir "NotificationFilter.ps1")

. (Join-Path $ProjectDir "NotificationReader.ps1")

. (Join-Path $ProjectDir "NotificationSender.ps1")

. (Join-Path $ProjectDir "Start-Dashboard.ps1")



# Create temporary isolated sandbox directory for tests

$sandboxDir = Join-Path $env:TEMP ("AppearancePrivacy_Test_" + [System.Guid]::NewGuid().ToString("N"))

New-Item -ItemType Directory -Path $sandboxDir -Force | Out-Null



$sandboxConfigPath = Join-Path $sandboxDir "config.json"

$initialConfig = @{

    DeviceName               = "Ibrahim-PC"

    PrivacyMode              = "TitleOnly"

    CustomPrivacyFields      = @{

        IncludeDeviceName = $true

        IncludeAppName    = $true

        IncludeTitle      = $true

        IncludeBody       = $false

    }

    AppFilterMode            = "Allowlist"

    AllowedAppIds            = @("WhatsApp", "Google Chrome", "Telegram")

    BlockedAppIds            = @("SpamApp", "BlockedSpamApp")

    NtfyServer               = "https://ntfy.sh"

    NtfyTopic                = "test-secret-topic"

    NtfyToken                = "tk_secret_123"

    LiveForwardingEnabled    = $true

    DryRun                   = $false

    PollIntervalSeconds      = 1.5

    RetryInitialDelaySeconds = 2.0

    MaxRetries               = 3

}

$initialConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $sandboxConfigPath -Encoding UTF8



function Test-LoadConfigWithJson {

    param($jsonObj)

    $tmp = Join-Path $sandboxDir ("cfg_" + [System.Guid]::NewGuid().ToString("N") + ".json")

    $jsonObj | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8

    $res = Load-AppConfig -ConfigPath $tmp

    Remove-Item $tmp -Force -ErrorAction SilentlyContinue

    return $res

}



# ==============================================================================

# Group 1: Device Name Defaults, Customization & Validation

# ==============================================================================

Write-Host "`n--- Group 1: Device Name Defaults & Validation ---" -ForegroundColor White



# 1.1 Defaults to Windows computer name when empty or missing

$loadedWithoutDevice = Test-LoadConfigWithJson @{

    NtfyServer = "https://ntfy.sh"

    NtfyTopic  = "test"

}

$expectedDefaultDevice = if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) { $env:COMPUTERNAME } else { "Windows-PC" }

Assert-Test -Name "Device name defaults to Windows computer name when unconfigured" -Condition ($loadedWithoutDevice.DeviceName -eq $expectedDefaultDevice) -Details "DeviceName=$($loadedWithoutDevice.DeviceName)"



# 1.2 Custom device names persist across restarts

$devResult = Set-DashboardDeviceName -Dir $sandboxDir -DeviceName "Custom-Laptop-Pro"

Assert-Test -Name "Set-DashboardDeviceName reports Success = True" -Condition ($devResult.Success -eq $true)

$savedCfg = Get-Content -Path $sandboxConfigPath -Raw | ConvertFrom-Json

Assert-Test -Name "Custom device name persists to config.json" -Condition ($savedCfg.DeviceName -eq "Custom-Laptop-Pro")



# 1.3 Atomic backup created during device name update

$bakPath = Join-Path $sandboxDir "config.json.bak"

Assert-Test -Name "Config backup file created on device name save" -Condition (Test-Path $bakPath)



# 1.4 Unrelated settings preserved

Assert-Test -Name "Unrelated NtfyToken preserved on device name update" -Condition ($savedCfg.NtfyToken -eq "tk_secret_123")

Assert-Test -Name "Unrelated AllowedAppIds preserved on device name update" -Condition ($savedCfg.AllowedAppIds -contains "WhatsApp")



# 1.5 Validation: reject empty or whitespace device name

$emptyDev = Set-DashboardDeviceName -Dir $sandboxDir -DeviceName "   "

Assert-Test -Name "Rejects empty or whitespace device name" -Condition ($emptyDev.Success -eq $false -and $emptyDev.Error -match "empty")



# 1.6 Validation: reject excessively long device name (> 64 characters)

$longName = "A" * 65

$longDev = Set-DashboardDeviceName -Dir $sandboxDir -DeviceName $longName

Assert-Test -Name "Rejects device name exceeding 64 characters" -Condition ($longDev.Success -eq $false -and $longDev.Error -match "64")



# 1.7 Validation: reject newline or control characters

$newlineDev = Set-DashboardDeviceName -Dir $sandboxDir -DeviceName "Bad`nName"

Assert-Test -Name "Rejects device name containing newline control characters" -Condition ($newlineDev.Success -eq $false)



# ==============================================================================

# Group 2: Privacy Modes Configuration, Validation & Persistence

# ==============================================================================

Write-Host "`n--- Group 2: Privacy Modes Configuration & Validation ---" -ForegroundColor White



# 2.1 Mode normalization in Load-AppConfig

$modesToTest = @("TitleOnly", "TitleAndApp", "TitleAndBody", "Custom")

foreach ($m in $modesToTest) {

    $c = Test-LoadConfigWithJson @{ PrivacyMode = $m }

    Assert-Test -Name "Load-AppConfig recognizes PrivacyMode '$m'" -Condition ($c.PrivacyMode -eq $m)

}



# 2.2 Invalid mode falls back safely to TitleOnly

$invalidCfg = Test-LoadConfigWithJson @{ PrivacyMode = "SuperPrivateNonExistent" }

Assert-Test -Name "Invalid privacy mode falls back safely to TitleOnly" -Condition ($invalidCfg.PrivacyMode -eq "TitleOnly")



# 2.3 Set-DashboardPrivacy accepts valid mode and persists

$privRes = Set-DashboardPrivacy -Dir $sandboxDir -PrivacyMode "TitleAndApp"

Assert-Test -Name "Set-DashboardPrivacy reports Success = True" -Condition ($privRes.Success -eq $true)

$savedCfg2 = Get-Content -Path $sandboxConfigPath -Raw | ConvertFrom-Json

Assert-Test -Name "PrivacyMode persists to config.json" -Condition ($savedCfg2.PrivacyMode -eq "TitleAndApp")



# 2.4 Set-DashboardPrivacy rejects invalid mode

$badPriv = Set-DashboardPrivacy -Dir $sandboxDir -PrivacyMode "HackedMode"

Assert-Test -Name "Set-DashboardPrivacy rejects invalid privacy mode" -Condition ($badPriv.Success -eq $false)



# 2.5 Custom mode with independent selection

$customPayload = @{

    IncludeDeviceName = $true

    IncludeAppName    = $false

    IncludeTitle      = $true

    IncludeBody       = $true

}

$custRes = Set-DashboardPrivacy -Dir $sandboxDir -PrivacyMode "Custom" -CustomFields $customPayload

Assert-Test -Name "Set-DashboardPrivacy saves Custom mode and fields" -Condition ($custRes.Success -eq $true)

$savedCfg3 = Get-Content -Path $sandboxConfigPath -Raw | ConvertFrom-Json

Assert-Test -Name "CustomPrivacyFields saved in config.json" -Condition ($savedCfg3.CustomPrivacyFields.IncludeBody -eq $true -and $savedCfg3.CustomPrivacyFields.IncludeAppName -eq $false)



# ==============================================================================

# Group 3: Privacy Modes Outgoing Request & Body Leak Prevention

# ==============================================================================

Write-Host "`n--- Group 3: Privacy Enforcement & Outgoing HTTP Payload ---" -ForegroundColor White



# Synthetic test notification with real-looking data

$syntheticRaw = [PSCustomObject]@{

    NotificationId = 9901

    AppDisplayName = "WhatsApp"

    AppUserModelId = "WhatsApp.Desktop"

    AppLabel       = "WhatsApp"

    Title          = "New Notification"

    Body           = "Message content appears here"

}



# Helper to capture outgoing request

function Send-MockCapture {

    param($Notification, $Config)

    $captured = [System.Collections.Generic.List[hashtable]]::new()

    $mockHandler = {

        param($Url, $Headers, $Body, $Attempt)

        $captured.Add(@{

            Url     = $Url

            Headers = $Headers

            Body    = $Body

            Attempt = $Attempt

        })

        return @{ StatusCode = 200 }

    }

    $res = Send-SingleAttempt -FilteredNotification $Notification -Config $Config -CustomHttpHandler $mockHandler

    return @{ Result = $res; Request = if ($captured.Count -gt 0) { $captured[0] } else { $null } }

}



$baseTestCfg = @{

    AppFilterMode         = "Allowlist"

    AllowedAppIds         = @("WhatsApp", "Google Chrome", "Telegram")

    BlockedAppIds         = @("SpamApp")

    NtfyServer            = "https://ntfy.sh"

    NtfyTopic             = "safe-topic"

    LiveForwardingEnabled = $true

}



# 3.1 Mode A: TitleOnly

# Requirement: Never transmits original notification body. Preserves Device Name & Title.

$cfgTitleOnly = $baseTestCfg.Clone()

$cfgTitleOnly["DeviceName"] = "Ibrahim-PC"

$cfgTitleOnly["PrivacyMode"] = "TitleOnly"



$filteredA = Filter-Notification -NotificationData $syntheticRaw -Config $cfgTitleOnly

$sendA = Send-MockCapture -Notification $filteredA -Config $cfgTitleOnly



Assert-Test -Name "TitleOnly: Filter suppresses Body to empty string" -Condition ($filteredA -ne $null -and $filteredA.Body -eq "")

Assert-Test -Name "TitleOnly: Outgoing Title header is configured DeviceName" -Condition ($sendA.Request -ne $null -and $sendA.Request.Headers["Title"] -eq "Ibrahim-PC")

Assert-Test -Name "TitleOnly: Outgoing Body payload contains original Title" -Condition ($sendA.Request.Body -match "New Notification")

Assert-Test -Name "TitleOnly: Outgoing request NEVER contains original Body" -Condition ($sendA.Request.Body -notmatch "Message content appears here")

Assert-Test -Name "TitleOnly: Outgoing headers NEVER contain original Body" -Condition (([string]($sendA.Request.Headers.Values -join " ")) -notmatch "Message content appears here")

Assert-Test -Name "TitleOnly: Outgoing tags include computer and bell indicators" -Condition ($sendA.Request.Headers["Tags"] -match "computer")



# 3.2 Mode B: TitleAndApp

# Requirement: Includes DeviceName, Application Name, Title; NEVER includes Body.

$cfgTitleAndApp = $baseTestCfg.Clone()

$cfgTitleAndApp["DeviceName"] = "Ibrahim-PC"

$cfgTitleAndApp["PrivacyMode"] = "TitleAndApp"



$filteredB = Filter-Notification -NotificationData $syntheticRaw -Config $cfgTitleAndApp

$sendB = Send-MockCapture -Notification $filteredB -Config $cfgTitleAndApp



Assert-Test -Name "TitleAndApp: Filter preserves AppLabel" -Condition ($filteredB -ne $null -and $filteredB.AppLabel -eq "WhatsApp")

Assert-Test -Name "TitleAndApp: Filter suppresses Body" -Condition ($filteredB -ne $null -and $filteredB.Body -eq "")

Assert-Test -Name "TitleAndApp: Title header is DeviceName" -Condition ($sendB.Request -ne $null -and $sendB.Request.Headers["Title"] -eq "Ibrahim-PC")

Assert-Test -Name "TitleAndApp: Body payload contains Application Name" -Condition ($sendB.Request.Body -match "WhatsApp")

Assert-Test -Name "TitleAndApp: Body payload contains original Title" -Condition ($sendB.Request.Body -match "New Notification")

Assert-Test -Name "TitleAndApp: Body payload strictly EXCLUDES original Body" -Condition ($sendB.Request.Body -notmatch "Message content appears here")



# 3.3 Mode C: TitleAndBody

# Requirement: Includes DeviceName, Application Name, Title, and full Body.

$cfgTitleAndBody = $baseTestCfg.Clone()

$cfgTitleAndBody["DeviceName"] = "Ibrahim-PC"

$cfgTitleAndBody["PrivacyMode"] = "TitleAndBody"



$filteredC = Filter-Notification -NotificationData $syntheticRaw -Config $cfgTitleAndBody

$sendC = Send-MockCapture -Notification $filteredC -Config $cfgTitleAndBody



Assert-Test -Name "TitleAndBody: Title header is DeviceName" -Condition ($sendC.Request -ne $null -and $sendC.Request.Headers["Title"] -eq "Ibrahim-PC")

Assert-Test -Name "TitleAndBody: Body payload contains Application Name" -Condition ($sendC.Request.Body -match "WhatsApp")

Assert-Test -Name "TitleAndBody: Body payload contains original Title" -Condition ($sendC.Request.Body -match "New Notification")

Assert-Test -Name "TitleAndBody: Body payload contains original Body" -Condition ($sendC.Request.Body -match "Message content appears here")



# 3.4 Mode D: Custom Field Combinations

# Custom Test 1: Only Device Name and Title (App and Body excluded)

$cfgCust1 = $baseTestCfg.Clone()

$cfgCust1["DeviceName"] = "Ibrahim-PC"

$cfgCust1["PrivacyMode"] = "Custom"

$cfgCust1["CustomPrivacyFields"] = @{

    IncludeDeviceName = $true

    IncludeAppName    = $false

    IncludeTitle      = $true

    IncludeBody       = $false

}

$filteredD1 = Filter-Notification -NotificationData $syntheticRaw -Config $cfgCust1

$sendD1 = Send-MockCapture -Notification $filteredD1 -Config $cfgCust1

Assert-Test -Name "Custom (Device+Title): Header has DeviceName" -Condition ($sendD1.Request -ne $null -and $sendD1.Request.Headers["Title"] -eq "Ibrahim-PC")

Assert-Test -Name "Custom (Device+Title): Body payload has Title" -Condition ($sendD1.Request.Body -match "New Notification")

Assert-Test -Name "Custom (Device+Title): Body payload excludes AppName" -Condition ($sendD1.Request.Body -notmatch "WhatsApp")

Assert-Test -Name "Custom (Device+Title): Body payload excludes Body" -Condition ($sendD1.Request.Body -notmatch "Message content appears here")



# Custom Test 2: App and Body only (DeviceName excluded from header, Title excluded)

$cfgCust2 = $baseTestCfg.Clone()

$cfgCust2["DeviceName"] = "Ibrahim-PC"

$cfgCust2["PrivacyMode"] = "Custom"

$cfgCust2["CustomPrivacyFields"] = @{

    IncludeDeviceName = $false

    IncludeAppName    = $true

    IncludeTitle      = $false

    IncludeBody       = $true

}

$filteredD2 = Filter-Notification -NotificationData $syntheticRaw -Config $cfgCust2

$sendD2 = Send-MockCapture -Notification $filteredD2 -Config $cfgCust2

Assert-Test -Name "Custom (App+Body): Header falls back to AppName when Device excluded" -Condition ($sendD2.Request -ne $null -and $sendD2.Request.Headers["Title"] -eq "WhatsApp")

Assert-Test -Name "Custom (App+Body): Body payload contains Message Body" -Condition ($sendD2.Request.Body -match "Message content appears here")

Assert-Test -Name "Custom (App+Body): Body payload excludes Title" -Condition ($sendD2.Request.Body -notmatch "New Notification")



# ==============================================================================

# Group 4: Missing Fields & Synthetic Resilience

# ==============================================================================

Write-Host "`n--- Group 4: Missing Fields & Resilience ---" -ForegroundColor White



$missingAppNotif = [PSCustomObject]@{

    NotificationId = 9902

    AppLabel       = ""

    Title          = "System Alert Title"

    Body           = "Some body text"

}

$sendMissingApp = Send-MockCapture -Notification $missingAppNotif -Config $cfgTitleAndApp

Assert-Test -Name "Handles missing application name safely without throwing" -Condition ($sendMissingApp.Result.Success -eq $true)

Assert-Test -Name "Payload contains Title when app is missing" -Condition ($sendMissingApp.Request.Body -match "System Alert Title")



$missingTitleNotif = [PSCustomObject]@{

    NotificationId = 9903

    AppLabel       = "Telegram"

    Title          = ""

    Body           = "Telegram message text"

}

$sendMissingTitle = Send-MockCapture -Notification $missingTitleNotif -Config $cfgTitleAndBody

Assert-Test -Name "Handles missing title safely without throwing" -Condition ($sendMissingTitle.Result.Success -eq $true)

Assert-Test -Name "Payload contains App and Body when title is empty" -Condition ($sendMissingTitle.Request.Body -match "Telegram" -and $sendMissingTitle.Request.Body -match "Telegram message text")



# ==============================================================================

# Group 5: ntfy Protocol Compatibility & Supported Fields

# ==============================================================================

Write-Host "`n--- Group 5: ntfy Protocol Compatibility ---" -ForegroundColor White



# Verify supported headers: only Title, Priority, Tags, Authorization

$supportedHeaders = @("Title", "Priority", "Tags", "Authorization")

$allHeadersSupported = $true

if ($sendC.Request) {

    foreach ($h in $sendC.Request.Headers.Keys) {

        if ($h -notin $supportedHeaders) {

            $allHeadersSupported = $false

            Write-Host "Unsupported header detected: $h" -ForegroundColor Yellow

        }

    }

} else {

    $allHeadersSupported = $false

}

Assert-Test -Name "Outgoing request uses only supported ntfy headers" -Condition ($allHeadersSupported -eq $true)

Assert-Test -Name "Priority is set to standard supported priority (3)" -Condition ($sendC.Request -ne $null -and $sendC.Request.Headers["Priority"] -eq "3")

Assert-Test -Name "Tags contains supported ntfy emoji shortcuts (computer,bell)" -Condition ($sendC.Request -ne $null -and $sendC.Request.Headers["Tags"] -eq "computer,bell")



# ==============================================================================

# Group 6: Dashboard Authentication, API Routes & English Verification

# ==============================================================================

Write-Host "`n--- Group 6: Dashboard Endpoints, UI & English Verification ---" -ForegroundColor White



# 6.1 Status includes DeviceName and CustomPrivacyFields

$statusObj = Get-DashboardStatus -Dir $sandboxDir

Assert-Test -Name "Get-DashboardStatus returns DeviceName" -Condition (-not [string]::IsNullOrWhiteSpace($statusObj.DeviceName))

Assert-Test -Name "Get-DashboardStatus returns CustomPrivacyFields" -Condition ($statusObj.CustomPrivacyFields -ne $null)



# 6.2 HTML Generation includes required appearance and privacy cards

$html = Get-DashboardHtml -AuthToken "TestToken123"

Assert-Test -Name "Dashboard HTML contains 'Notification Appearance' card" -Condition ($html -match "Notification Appearance")

Assert-Test -Name "Dashboard HTML contains Device Name input (txtDeviceName)" -Condition ($html -match 'id="txtDeviceName"')

Assert-Test -Name "Dashboard HTML contains Save Device Name button" -Condition ($html -match 'id="btnSaveDeviceName"')

Assert-Test -Name "Dashboard HTML contains Live Notification Preview container" -Condition ($html -match 'class="preview-box"')

Assert-Test -Name "Dashboard HTML contains preview elements (prevDevice, prevApp, prevTitle, prevBody)" -Condition ($html -match 'id="prevDevice"' -and $html -match 'id="prevApp"' -and $html -match 'id="prevTitle"' -and $html -match 'id="prevBody"')

Assert-Test -Name "Dashboard HTML explains ntfy iOS icon limitation" -Condition ($html -match "Apple iOS strictly restricts push notification icons")

Assert-Test -Name "Dashboard HTML contains 'Notification Privacy Controls' card" -Condition ($html -match "Notification Privacy Controls")

Assert-Test -Name "Dashboard HTML contains Mode A TitleOnly radio" -Condition ($html -match 'id="modeTitleOnly"')

Assert-Test -Name "Dashboard HTML contains Mode B TitleAndApp radio" -Condition ($html -match 'id="modeTitleAndApp"')

Assert-Test -Name "Dashboard HTML contains Mode C TitleAndBody radio" -Condition ($html -match 'id="modeTitleAndBody"')

Assert-Test -Name "Dashboard HTML contains Mode D Custom radio" -Condition ($html -match 'id="modeCustom"')

Assert-Test -Name "Dashboard HTML contains Custom fields panel and checkboxes" -Condition ($html -match 'id="customFieldsPanel"' -and $html -match 'id="chkCustBody"')

Assert-Test -Name "Dashboard HTML contains Security Warning alert for body forwarding" -Condition ($html -match 'id="bodyWarningBox"')

Assert-Test -Name "Dashboard HTML contains Save Privacy Settings button" -Condition ($html -match 'id="btnSavePrivacy"')



# 6.3 Strictly English Language Verification

# Ensure zero Arabic unicode characters in HTML output

$hasArabicInHtml = [regex]::IsMatch($html, '[؀-ۿ]')

Assert-Test -Name "Dashboard HTML contains ZERO Arabic characters (exclusively English)" -Condition ($hasArabicInHtml -eq $false)



# Verify zero Arabic characters in production files newly modified

$scriptsToCheck = @("Config.ps1", "NotificationSender.ps1", "NotificationFilter.ps1", "NotificationReader.ps1", "Start-Dashboard.ps1")

$allEnglish = $true

foreach ($s in $scriptsToCheck) {

    $scriptContent = Get-Content -Path (Join-Path $ProjectDir $s) -Raw -Encoding UTF8

    if ([regex]::IsMatch($scriptContent, '[؀-ۿ]')) {

        $allEnglish = $false

        Write-Host "Found Arabic character in $s" -ForegroundColor Red

    }

}

Assert-Test -Name "All modified scripts contain ZERO Arabic characters (exclusively English)" -Condition ($allEnglish -eq $true)



# ==============================================================================

# Group 7: Application Filtering & Production Safety Verification

# ==============================================================================

Write-Host "`n--- Group 7: App Filtering & Production Safety Verification ---" -ForegroundColor White



# 7.1 Verify application filtering still blocks unlisted app in Allowlist mode

$blockedRaw = [PSCustomObject]@{

    NotificationId = 9904

    AppDisplayName = "BlockedSpamApp"

    AppUserModelId = "BlockedSpamApp_12345"

    Title          = "Spam Notification"

    Body           = "Spam body"

}

$filterResult = Filter-Notification -NotificationData $blockedRaw -Config $initialConfig

Assert-Test -Name "Existing Allowlist application filtering continues to block unlisted app" -Condition ($filterResult -eq $null)



# 7.2 Allowed app passes

$allowedRaw = [PSCustomObject]@{

    NotificationId = 9905

    AppDisplayName = "WhatsApp"

    AppUserModelId = "WhatsApp_12345"

    Title          = "Message from Alice"

    Body           = "Hello!"

}

$filterAllowed = Filter-Notification -NotificationData $allowedRaw -Config $initialConfig

Assert-Test -Name "Existing Allowlist application filtering continues to allow whitelisted app" -Condition ($filterAllowed -ne $null)



# 7.3 Verify production forwarder process is still healthy

$prodProcInfo = Get-ActiveForwarderProcessInfo -Dir $ProjectDir

Assert-Test -Name "Production forwarder process remains running" -Condition ($prodProcInfo -ne $null)



# Cleanup sandbox

Remove-Item -Path $sandboxDir -Recurse -Force -ErrorAction SilentlyContinue



# ==============================================================================

# Summary

# ==============================================================================

Write-Host "`n==========================================================" -ForegroundColor Cyan

Write-Host " Appearance & Privacy Test Execution Summary" -ForegroundColor Cyan

Write-Host "==========================================================" -ForegroundColor Cyan

Write-Host "  Total Tests: $($Global:PassedCount + $Global:FailedCount)" -ForegroundColor White

Write-Host "  Passed:      $($Global:PassedCount)" -ForegroundColor Green

Write-Host "  Failed:      $($Global:FailedCount)" -ForegroundColor $(if ($Global:FailedCount -eq 0) { "Green" } else { "Red" })



if ($Global:FailedCount -gt 0) {

    Write-Host "`nFailed Tests List:" -ForegroundColor Red

    $Global:FailedTests | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }

    exit 1

} else {

    Write-Host "`nAll Notification Appearance & Privacy tests passed successfully!" -ForegroundColor Green

    exit 0

}

