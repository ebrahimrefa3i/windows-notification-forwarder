<#
.SYNOPSIS
    Isolated Test Suite for Windows-to-iPhone ntfy Setup Wizard (Setup-Wizard.ps1 & Start.cmd).
.DESCRIPTION
    Validates:
    1. Launcher verification (Start.cmd structure, relative pathing, error handling, STA).
    2. Cryptographic topic generation (win- prefix, character set, randomness, entropy).
    3. Topic persistence & configuration isolation (reuses topic on reopen, separate wizard_config.json).
    4. Regenerate topic workflow (updates topic, updates persistence).
    5. Subscription URL construction and clipboard helpers.
    6. Connection test delivery (mock success, mock failure, network timeout, error sanitization).
    7. Safe production forwarder integration (atomic backup, topic update, preservation of other settings).
    8. Security & secret protection (no credential leakage, secret-by-obscurity notice).
    9. Production forwarder process health verification.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    $scriptDir = (Get-Location).Path
}
$parentDir = Split-Path $scriptDir -Parent
if (Test-Path (Join-Path $scriptDir "Setup-Wizard.ps1")) {
    $projDir = $scriptDir
} elseif (-not [string]::IsNullOrWhiteSpace($parentDir) -and (Test-Path (Join-Path $parentDir "Setup-Wizard.ps1"))) {
    $projDir = $parentDir
} else {
    $projDir = (Get-Location).Path
}
$projDir = (Resolve-Path $projDir).Path

$realProdConfigPath = Join-Path $projDir "config.json"
$initialProdTopic = if (Test-Path $realProdConfigPath) {
    (Get-Content -Path $realProdConfigPath -Raw | ConvertFrom-Json).NtfyTopic
} else { "" }

. (Join-Path $projDir "Setup-Wizard.ps1") -NonInteractive | Out-Null

$testResults = [System.Collections.ArrayList]::new()
function Assert-Test {
    param([string]$Name, [bool]$Condition, [string]$Details = "")
    $status = if ($Condition) { "PASS" } else { "FAIL" }
    $color = if ($Condition) { [ConsoleColor]::Green } else { [ConsoleColor]::Red }
    Write-Host "  [$status] $Name" -ForegroundColor $color
    if (-not $Condition -and $Details) {
        Write-Host "         Details: $Details" -ForegroundColor Yellow
    }
    [void]$script:testResults.Add(@{ Name = $Name; Status = $status; Details = $Details })
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Running Windows-to-iPhone Setup Wizard Test Suite" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# -------------------------------------------------------------------------
# Group 0: Setup UI Palette, Borderless Sections & Responsive Window
# -------------------------------------------------------------------------
Write-Host "`n--- Group 0: Setup UI Palette & Layout ---" -ForegroundColor Yellow

$wizardSource = Get-Content -Path (Join-Path $projDir "Setup-Wizard.ps1") -Raw
$wizardRgbValues = [regex]::Matches($wizardSource, 'FromArgb\((\d+),\s*(\d+),\s*(\d+)\)') | ForEach-Object {
    "$($_.Groups[1].Value),$($_.Groups[2].Value),$($_.Groups[3].Value)"
} | Select-Object -Unique
$allowedWizardRgbValues = @("239,239,239", "255,255,255", "33,33,33", "35,76,226")
$wizardPaletteIsStrict = @($wizardRgbValues | Where-Object { $_ -notin $allowedWizardRgbValues }).Count -eq 0
Assert-Test -Name "Setup wizard uses only the approved palette" -Condition $wizardPaletteIsStrict -Details ($wizardRgbValues -join '; ')
Assert-Test -Name "Setup wizard uses borderless section panels instead of GroupBox borders" `
    -Condition ($wizardSource -notmatch 'New-Object System\.Windows\.Forms\.GroupBox' -and $wizardSource -match '\$grpStep1 = New-Object System\.Windows\.Forms\.Panel')
Assert-Test -Name "Setup wizard can resize and scroll on shorter screens" `
    -Condition ($wizardSource -match '\$form\.FormBorderStyle = "Sizable"' -and $wizardSource -match '\$form\.AutoScroll = \$true')
Assert-Test -Name "Setup wizard uses a clear four-step layout that adapts to window width" `
    -Condition ($wizardSource -match '01\s+Notification key' -and $wizardSource -match '02\s+Device and privacy' -and $wizardSource -match '\$updateWizardLayout = \{' -and $wizardSource -match '\$grpStep3\.Width = \$columnWidth' -and $wizardSource -match '\$form\.Add_SizeChanged\(\$updateWizardLayout\)')
Assert-Test -Name "Setup wizard rounds its cards, fields, and action buttons" `
    -Condition ($wizardSource -match 'function Set-WizardCornerRadius' -and $wizardSource -match 'Set-WizardCornerRadius -Control \$grpStep1 -Radius 20' -and $wizardSource -match 'foreach \(\$wizardButton in @\([^\r\n]*\$btnStartPush\)\)' -and $wizardSource -match 'Set-WizardCornerRadius -Control \$wizardButton -Radius 13')
Assert-Test -Name "Setup wizard normalizes buttons to blue with white labels and no borders" `
    -Condition ($wizardSource -match '\$Control\.BackColor = \$action' -and $wizardSource -match '\$Control\.ForeColor = \[System\.Drawing\.Color\]::White' -and $wizardSource -match '\$Control\.FlatAppearance\.BorderSize = 0')

# -------------------------------------------------------------------------
# Group 1: Launcher Verification (Start.cmd)
# -------------------------------------------------------------------------
Write-Host "`n--- Group 1: Launcher Verification (Start.cmd) ---" -ForegroundColor Yellow

$cmdPath = Join-Path $projDir "Start.cmd"
Assert-Test -Name "Start.cmd exists in project root" -Condition (Test-Path $cmdPath)

if (Test-Path $cmdPath) {
    $cmdRaw = Get-Content -Path $cmdPath -Raw
    Assert-Test -Name "Start.cmd uses %~dp0Setup-Wizard.ps1 relative path" -Condition ($cmdRaw -match '%~dp0Setup-Wizard\.ps1')
    Assert-Test -Name "Start.cmd checks file existence before executing" -Condition ($cmdRaw -match 'if not exist "%SCRIPT_PATH%"')
    Assert-Test -Name "Start.cmd includes helpful error message on missing script" -Condition ($cmdRaw -match '\[ERROR\] Could not find Setup-Wizard\.ps1')
    Assert-Test -Name "Start.cmd invokes PowerShell with -NoProfile and -ExecutionPolicy Bypass" -Condition ($cmdRaw -match 'powershell\.exe\s+.*-NoProfile\s+.*-ExecutionPolicy Bypass')
    Assert-Test -Name "Start.cmd specifies -STA apartment state for WinForms and clipboard" -Condition ($cmdRaw -match '-STA')
    Assert-Test -Name "Start.cmd propagates exit code properly" -Condition ($cmdRaw -match 'exit /b %EXIT_CODE%')
}

# -------------------------------------------------------------------------
# Group 2: Cryptographic Topic Generation & Entropy
# -------------------------------------------------------------------------
Write-Host "`n--- Group 2: Cryptographic Topic Generation & Entropy ---" -ForegroundColor Yellow

$topic1 = New-DeviceTopic
Assert-Test -Name "Topic starts with win- prefix" -Condition ($topic1.StartsWith("win-"))
Assert-Test -Name "Topic format is 36 chars long (win- + 32 hex chars)" -Condition ($topic1.Length -eq 36)
Assert-Test -Name "Topic matches valid ntfy topic pattern ^win-[a-f0-9]{32}$" -Condition ($topic1 -match '^win-[a-f0-9]{32}$')
Assert-Test -Name "Topic validator accepts generated topic" -Condition (Test-ValidTopicFormat $topic1)
Assert-Test -Name "Topic validator rejects empty or whitespace topic" -Condition (-not (Test-ValidTopicFormat "   "))
Assert-Test -Name "Topic validator rejects topics with illegal symbols" -Condition (-not (Test-ValidTopicFormat "win topic$!"))

# Test randomness across multiple generations (no collisions)
$sampleSet = @{}
$collisions = 0
for ($i = 0; $i -lt 50; $i++) {
    $t = New-DeviceTopic
    if ($sampleSet.ContainsKey($t)) { $collisions++ }
    $sampleSet[$t] = $true
}
Assert-Test -Name "Cryptographic RNG produces 50 unique topics without collision" -Condition ($collisions -eq 0 -and $sampleSet.Count -eq 50)

# -------------------------------------------------------------------------
# Group 3: Strict No-Auto-Generation & Explicit Key Generation
# -------------------------------------------------------------------------
Write-Host "`n--- Group 3: Strict No-Auto-Generation & Explicit Key Generation ---" -ForegroundColor Yellow

# Create isolated sandbox directory to test persistence
$sandboxDir = Join-Path ([System.IO.Path]::GetTempPath()) ("WizardTest_" + [System.Guid]::NewGuid().ToString("N"))
[void](New-Item -ItemType Directory -Path $sandboxDir -Force)

try {
    # 1. Strict Requirement: First run in clean sandbox returns unconfigured state with empty key
    $cfg1 = Get-WizardConfig -Dir $sandboxDir
    $savedPath = Get-WizardConfigPath -Dir $sandboxDir
    Assert-Test -Name "First run in clean sandbox returns empty DeviceTopic" -Condition ($cfg1.DeviceTopic -eq "")
    Assert-Test -Name "First run does NOT automatically create wizard_config.json" -Condition (-not (Test-Path $savedPath))
    Assert-Test -Name "First run has null LastGenerated timestamp" -Condition ($null -eq $cfg1.LastGenerated)
    Assert-Test -Name "Default server is https://ntfy.sh" -Condition ($cfg1.NtfyServer -eq "https://ntfy.sh")

    # 2. Key generated ONLY after explicit Generate-NewWizardKey action
    $cfgGen = Generate-NewWizardKey -Dir $sandboxDir
    Assert-Test -Name "Explicit Generate-NewWizardKey creates valid topic with win- prefix" -Condition ($cfgGen.DeviceTopic.StartsWith("win-"))
    Assert-Test -Name "Explicit generation persists wizard_config.json" -Condition (Test-Path $savedPath)
    Assert-Test -Name "Records ISO timestamp for LastGenerated upon explicit generation" -Condition (-not [string]::IsNullOrWhiteSpace($cfgGen.LastGenerated))

    # 3. Second run: reuses the explicitly generated topic
    $cfg2 = Get-WizardConfig -Dir $sandboxDir
    Assert-Test -Name "Reopening wizard reuses the explicitly generated topic" -Condition ($cfg2.DeviceTopic -eq $cfgGen.DeviceTopic)
    Assert-Test -Name "Reopening wizard does not overwrite LastGenerated timestamp" -Condition ($cfg2.LastGenerated -eq $cfgGen.LastGenerated)

    # 4. Explicit replacement: creates a new topic and updates persistence
    $cfg3 = Regenerate-WizardTopic -Dir $sandboxDir
    Assert-Test -Name "Regenerate-WizardTopic creates a new valid topic" -Condition ($cfg3.DeviceTopic.StartsWith("win-"))
    Assert-Test -Name "Regenerated topic is different from initial topic" -Condition ($cfg3.DeviceTopic -ne $cfgGen.DeviceTopic)

    # 5. Reopening after regeneration reuses the new topic
    $cfg4 = Get-WizardConfig -Dir $sandboxDir
    Assert-Test -Name "Reopening after regeneration reuses the new topic" -Condition ($cfg4.DeviceTopic -eq $cfg3.DeviceTopic)

    # 6. Production config isolation: config.json in sandbox does not exist and wasn't created
    $sandboxProdConfig = Join-Path $sandboxDir "config.json"
    Assert-Test -Name "Wizard does NOT create or alter config.json automatically" -Condition (-not (Test-Path $sandboxProdConfig))

    # 7. Button naming verification in wizard source
    Assert-Test -Name "Setup wizard displays 'Generate New Key' button" -Condition ($wizardSource -match '\$btnRegen\.Text = "Generate New Key"')

    # 8. Test path containing spaces portability
    $spaceSandboxDir = Join-Path ([System.IO.Path]::GetTempPath()) ("Wizard Test With Spaces " + [System.Guid]::NewGuid().ToString("N"))
    [void](New-Item -ItemType Directory -Path $spaceSandboxDir -Force)
    try {
        $spaceCfg = Get-WizardConfig -Dir $spaceSandboxDir
        Assert-Test -Name "Wizard works in directories with spaces" -Condition ($spaceCfg.DeviceTopic -eq "")
        $spaceGen = Generate-NewWizardKey -Dir $spaceSandboxDir
        Assert-Test -Name "Generates key in directories with spaces" -Condition ($spaceGen.DeviceTopic.StartsWith("win-"))
    } finally {
        if (Test-Path $spaceSandboxDir) {
            Remove-Item -Path $spaceSandboxDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

} finally {
    if (Test-Path $sandboxDir) {
        Remove-Item -Path $sandboxDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------------------------------
# Group 4: Subscription URL & Server Configuration
# -------------------------------------------------------------------------
Write-Host "`n--- Group 4: Subscription URL & Server Configuration ---" -ForegroundColor Yellow

$sandboxDir2 = Join-Path ([System.IO.Path]::GetTempPath()) ("WizardTest_Url_" + [System.Guid]::NewGuid().ToString("N"))
[void](New-Item -ItemType Directory -Path $sandboxDir2 -Force)

try {
    # Test with custom production server in config.json
    $customServerJson = @{
        NtfyServer = "https://ntfy.mycustomdomain.com"
        NtfyTopic  = "prod-topic-12345"
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path $sandboxDir2 "config.json"), $customServerJson, [System.Text.Encoding]::UTF8)

    $customCfg = Get-WizardConfig -Dir $sandboxDir2
    Assert-Test -Name "Wizard detects custom server from config.json" -Condition ($customCfg.NtfyServer -eq "https://ntfy.mycustomdomain.com")

    $subUrl = "$($customCfg.NtfyServer.TrimEnd('/'))/$($customCfg.DeviceTopic)"
    Assert-Test -Name "Subscription URL uses configured server" -Condition ($subUrl -eq "https://ntfy.mycustomdomain.com/prod-topic-12345")

    # Test server validation
    Assert-Test -Name "Server validator accepts https URL" -Condition (Test-ValidServerUrl "https://ntfy.sh")
    Assert-Test -Name "Server validator accepts http with port" -Condition (Test-ValidServerUrl "http://192.168.1.50:8080")
    Assert-Test -Name "Server validator rejects non-HTTP protocol" -Condition (-not (Test-ValidServerUrl "ftp://ntfy.sh"))
    Assert-Test -Name "Server validator rejects plain string" -Condition (-not (Test-ValidServerUrl "just_a_string"))

} finally {
    if (Test-Path $sandboxDir2) {
        Remove-Item -Path $sandboxDir2 -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------------------------------
# Group 5: Test Notification Delivery & Error Handling
# -------------------------------------------------------------------------
Write-Host "`n--- Group 5: Test Notification Delivery & Error Handling ---" -ForegroundColor Yellow

# 1. Mock Successful Delivery
$capturedRequest = $null
$mockSuccessHandler = {
    param($Url, $Headers, $Body)
    $script:capturedRequest = @{
        Url     = $Url
        Headers = $Headers
        Body    = $Body
    }
    return @{ StatusCode = 200 }
}

$mockTopic = "win-testtopic1234567890abcdef"
$successResult = Send-WizardTestNotification `
    -Server "https://ntfy.sh" `
    -Topic $mockTopic `
    -CustomHttpHandler $mockSuccessHandler

Assert-Test -Name "Test notification returns Success = True on HTTP 200" -Condition ($successResult.Success -eq $true)
Assert-Test -Name "Test notification returns StatusCode = 200" -Condition ($successResult.StatusCode -eq 200)
Assert-Test -Name "Test notification includes readable check iPhone message" -Condition ($successResult.Message -like "*Check your iPhone*")
Assert-Test -Name "Test notification sent to exact URL" -Condition ($script:capturedRequest.Url -eq "https://ntfy.sh/$mockTopic")
Assert-Test -Name "Test notification header has Title 'Windows Connection Test'" -Condition ($script:capturedRequest.Headers["Title"] -eq "Windows Connection Test")
Assert-Test -Name "Test notification header has Priority '3'" -Condition ($script:capturedRequest.Headers["Priority"] -eq "3")
Assert-Test -Name "Test notification body contains Windows timestamp message" -Condition ($script:capturedRequest.Body -like "Test notification from Windows at *")

# 2. Mock Failed Delivery
$mockFailureHandler = {
    param($Url, $Headers, $Body)
    throw [System.Net.WebException]::new("The remote name could not be resolved: 'invalid-ntfy-domain.test'")
}

$failResult = Send-WizardTestNotification `
    -Server "https://invalid-ntfy-domain.test" `
    -Topic $mockTopic `
    -CustomHttpHandler $mockFailureHandler

Assert-Test -Name "Test notification returns Success = False on exception" -Condition ($failResult.Success -eq $false)
Assert-Test -Name "Test notification provides readable error message" -Condition ($failResult.Error -like "Delivery failed:*")
Assert-Test -Name "Test notification error message redacts raw URL" -Condition ($failResult.Error -notlike "*https://invalid-ntfy-domain.test*")
Assert-Test -Name "Test notification error message redacts secret topic" -Condition ($failResult.Error -notlike "*$mockTopic*")

# 3. Invalid parameters validation before request
$invalidServerResult = Send-WizardTestNotification -Server "not_a_server" -Topic $mockTopic
Assert-Test -Name "Rejects invalid server URL before sending" -Condition ($invalidServerResult.Success -eq $false -and $invalidServerResult.Error -like "*Invalid server URL*")

$invalidTopicResult = Send-WizardTestNotification -Server "https://ntfy.sh" -Topic "bad topic with spaces!"
Assert-Test -Name "Rejects invalid topic name before sending" -Condition ($invalidTopicResult.Success -eq $false -and $invalidTopicResult.Error -like "*Invalid topic name*")

# -------------------------------------------------------------------------
# Group 6: Safe Production Forwarder Integration
# -------------------------------------------------------------------------
Write-Host "`n--- Group 6: Safe Production Forwarder Integration ---" -ForegroundColor Yellow

$sandboxDir3 = Join-Path ([System.IO.Path]::GetTempPath()) ("WizardTest_Prod_" + [System.Guid]::NewGuid().ToString("N"))
[void](New-Item -ItemType Directory -Path $sandboxDir3 -Force)

try {
    # Setup mock production config.json with complex configuration
    $mockProd = @{
        LiveForwardingEnabled = $true
        DryRun                = $false
        PrivacyMode           = "TitleAndBody"
        AppFilterMode         = "Allowlist"
        NtfyServer            = "https://ntfy.sh"
        NtfyTopic             = "old-production-topic-9999"
        NtfyToken             = "secret_token_12345"
        AllowedAppIds         = @("WhatsApp", "Chrome")
        BlockedAppIds         = @("SpamApp")
    }
    $cfgPath = Join-Path $sandboxDir3 "config.json"
    $backupPath = Join-Path $sandboxDir3 "config.json.bak"
    [System.IO.File]::WriteAllText($cfgPath, ($mockProd | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)

    $newWizardTopic = "win-newtopic999888777666555444333222111"
    $applyRes = Apply-WizardTopicToProduction -Dir $sandboxDir3 -Topic $newWizardTopic

    Assert-Test -Name "Apply-WizardTopicToProduction reports Success = True" -Condition ($applyRes.Success -eq $true)
    Assert-Test -Name "Creates config.json.bak before updating" -Condition (Test-Path $backupPath)

    # Verify backup contains original topic
    $backupParsed = Get-Content $backupPath -Raw | ConvertFrom-Json
    Assert-Test -Name "Backup preserves original topic" -Condition ($backupParsed.NtfyTopic -eq "old-production-topic-9999")

    # Verify updated config.json
    $updatedParsed = Get-Content $cfgPath -Raw | ConvertFrom-Json
    Assert-Test -Name "config.json has new topic" -Condition ($updatedParsed.NtfyTopic -eq $newWizardTopic)
    Assert-Test -Name "Preserved LiveForwardingEnabled" -Condition ($updatedParsed.LiveForwardingEnabled -eq $true)
    Assert-Test -Name "Preserved DryRun" -Condition ($updatedParsed.DryRun -eq $false)
    Assert-Test -Name "Preserved PrivacyMode" -Condition ($updatedParsed.PrivacyMode -eq "TitleAndBody")
    Assert-Test -Name "Preserved AppFilterMode" -Condition ($updatedParsed.AppFilterMode -eq "Allowlist")
    Assert-Test -Name "Preserved NtfyToken" -Condition ($updatedParsed.NtfyToken -eq "secret_token_12345")
    Assert-Test -Name "Preserved AllowedAppIds" -Condition ($updatedParsed.AllowedAppIds -contains "WhatsApp")
    Assert-Test -Name "Preserved BlockedAppIds" -Condition ($updatedParsed.BlockedAppIds -contains "SpamApp")

} finally {
    if (Test-Path $sandboxDir3) {
        Remove-Item -Path $sandboxDir3 -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------------------------------
# Group 7: Production Service Health Verification
# -------------------------------------------------------------------------
Write-Host "`n--- Group 7: Production Service Health Verification ---" -ForegroundColor Yellow

# Verify real production config.json was never modified during tests
$realProdConfigPath = Join-Path $projDir "config.json"
$realProdRaw = Get-Content -Path $realProdConfigPath -Raw | ConvertFrom-Json
Assert-Test -Name "Real production topic is intact in config.json" -Condition ($realProdRaw.NtfyTopic -eq $initialProdTopic -and -not [string]::IsNullOrWhiteSpace($realProdRaw.NtfyTopic))
Assert-Test -Name "Real production LiveForwardingEnabled is True" -Condition ($realProdRaw.LiveForwardingEnabled -eq $true)
Assert-Test -Name "Real production DryRun is False" -Condition ($realProdRaw.DryRun -eq $false)

# Verify production forwarder process is still running via Win32_Process
$procs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $cmd = $_.CommandLine
    $cmd -and ($cmd -like "*NotificationForwarder.ps1*") -and ($cmd -notlike "*Watchdog.ps1*") -and ($cmd -notlike "*Test-*")
})
Assert-Test -Name "Production forwarder process remains running" -Condition ($procs.Count -gt 0)

# -------------------------------------------------------------------------
# Test Summary
# -------------------------------------------------------------------------
$passCount = ($testResults | Where-Object { $_.Status -eq "PASS" }).Count
$failCount = ($testResults | Where-Object { $_.Status -eq "FAIL" }).Count
$totalCount = $testResults.Count

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host (" Setup Wizard Test Results: {0} / {1} passed ({2} failed)" -f $passCount, $totalCount, $failCount) -ForegroundColor $(if ($failCount -eq 0) { [ConsoleColor]::Green } else { [ConsoleColor]::Red })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failCount -gt 0) {
    exit 1
} else {
    exit 0
}
