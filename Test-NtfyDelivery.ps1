<#
.SYNOPSIS
    Standalone synthetic delivery test for Windows-to-iPhone Notification Forwarder.
.DESCRIPTION
    Safely verifies network delivery to your configured ntfy topic on iPhone by sending
    exactly one fixed synthetic test message without reading Windows notifications or
    running the forwarder's background polling loop.
    Requires the explicit -ConfirmSyntheticSend switch before making any network request.
    Never exposes topic names, authorization tokens, request URLs, or headers.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$ConfirmSyntheticSend,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [scriptblock]$CustomHttpHandler = $null
)

$ErrorActionPreference = "Stop"

# Set TLS 1.2/1.3 security protocol
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls

# Resolve script directory
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    $scriptDir = (Get-Location).Path
}

# Optional dot-source of Config.ps1 for shared sanitizer if available
$configModule = Join-Path -Path $scriptDir -ChildPath "Config.ps1"
if (Test-Path -Path $configModule) {
    . $configModule
}

function Get-DeliveryTestSanitized {
    param(
        [Parameter(Mandatory = $true)]
        $InputMessage,

        [Parameter(Mandatory = $false)]
        [hashtable]$Config = $null
    )

    if (Get-Command "Get-SanitizedMessage" -ErrorAction SilentlyContinue) {
        return Get-SanitizedMessage -InputMessage $InputMessage -Config $Config
    }

    $raw = if ($InputMessage -is [System.Exception]) {
        $msg = $InputMessage.Message
        if ($InputMessage.InnerException -and -not [string]::IsNullOrWhiteSpace($InputMessage.InnerException.Message)) {
            $msg += " | " + $InputMessage.InnerException.Message
        }
        $msg
    } else {
        [string]$InputMessage
    }

    $clean = $raw -replace 'https?://[^\s''"<>]+', '[URL REDACTED]'
    $clean = $clean -replace '(?i)Bearer\s+[a-zA-Z0-9_\-\.\:]+', 'Bearer [TOKEN REDACTED]'
    $clean = $clean -replace '(?i)(token|key|secret|password|auth|authorization)\s*[:=]\s*[^\s,;]+', '$1=[REDACTED]'

    if ($Config) {
        if (-not [string]::IsNullOrWhiteSpace($Config.NtfyTopic)) {
            $clean = $clean.Replace($Config.NtfyTopic, '[TOPIC REDACTED]')
        }
        if (-not [string]::IsNullOrWhiteSpace($Config.NtfyToken)) {
            $clean = $clean.Replace($Config.NtfyToken, '[TOKEN REDACTED]')
        }
        if (-not [string]::IsNullOrWhiteSpace($Config.NtfyServer)) {
            $clean = $clean.Replace($Config.NtfyServer, '[SERVER REDACTED]')
        }
    }
    return $clean
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  ntfy Synthetic Delivery Verification (Standalone Test)" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Safety Gate: Require explicit switch before network request
if (-not $ConfirmSyntheticSend.IsPresent) {
    Write-Host "`n[SAFETY GATE] No network request made." -ForegroundColor Yellow
    Write-Host "This script verifies end-to-end delivery of notifications to your iPhone" -ForegroundColor White
    Write-Host "by transmitting exactly ONE fixed synthetic test message over HTTPS." -ForegroundColor White
    Write-Host "`nFixed synthetic payload to be sent:" -ForegroundColor White
    Write-Host "  Title: Notification Forwarder Test" -ForegroundColor Gray
    Write-Host "  Body:  Synthetic test message. No personal notification data." -ForegroundColor Gray
    Write-Host "`nSafety guarantees:" -ForegroundColor White
    Write-Host "  - Windows notification listener is NOT initialized." -ForegroundColor Gray
    Write-Host "  - Notification store is NOT accessed." -ForegroundColor Gray
    Write-Host "  - Arbitrary custom payloads are NOT supported." -ForegroundColor Gray
    Write-Host "  - Strict HTTPS with standard certificate validation is enforced." -ForegroundColor Gray
    Write-Host "  - Server URLs, secret topics, and tokens are NEVER printed." -ForegroundColor Gray
    Write-Host "`nTo perform the delivery test to your iPhone, run with -ConfirmSyntheticSend:" -ForegroundColor Cyan
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\Test-NtfyDelivery.ps1 -ConfirmSyntheticSend`n" -ForegroundColor Green
    return
}

# 2. Resolve and load configuration
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path -Path $scriptDir -ChildPath "config.json"
}

if (-not (Test-Path -Path $ConfigPath)) {
    Write-Host "[CONFIG ERROR] Configuration file not found at: '$ConfigPath'." -ForegroundColor Red
    Write-Host "Please create 'config.json' from 'config.example.json' with your ntfy settings before running delivery tests." -ForegroundColor Yellow
    exit 1
}

try {
    $rawJson = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop
    $configData = $rawJson | ConvertFrom-Json -ErrorAction Stop
} catch {
    $cleanErr = Get-DeliveryTestSanitized -InputMessage $_.Exception
    Write-Host "[CONFIG ERROR] Failed to parse '$ConfigPath': $cleanErr" -ForegroundColor Red
    exit 1
}

$server = if ($configData.PSObject.Properties.Match("NtfyServer").Count -gt 0) { [string]$configData.NtfyServer } else { "https://ntfy.sh" }
$topic  = if ($configData.PSObject.Properties.Match("NtfyTopic").Count -gt 0) { [string]$configData.NtfyTopic } else { "" }
$token  = if ($configData.PSObject.Properties.Match("NtfyToken").Count -gt 0) { [string]$configData.NtfyToken } else { "" }

$safeConfig = @{
    NtfyServer = $server
    NtfyTopic  = $topic
    NtfyToken  = $token
}

# 3. Validation
if ([string]::IsNullOrWhiteSpace($topic)) {
    Write-Host "[VALIDATION ERROR] 'NtfyTopic' is not configured in '$ConfigPath'. Please configure a valid topic string." -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($server) -or -not ($server -like "https://*")) {
    Write-Host "[VALIDATION ERROR] NtfyServer must use secure HTTPS (e.g. 'https://ntfy.sh'). Insecure HTTP is not allowed." -ForegroundColor Red
    exit 1
}

if ($topic -match '[\r\n\t\s/\\#\?]') {
    Write-Host "[VALIDATION ERROR] NtfyTopic contains invalid characters (whitespace, slashes, or query characters are not allowed)." -ForegroundColor Red
    exit 1
}

# 4. Fixed Synthetic Payload (Never arbitrary)
$fixedTitle = "Notification Forwarder Test"
$fixedBody  = "Synthetic test message. No personal notification data."

$serverClean = $server.TrimEnd('/')
$endpointUrl = "$serverClean/$topic"

$headers = @{
    "Title"    = $fixedTitle
    "Priority" = "3"
    "Tags"     = "bell"
}

if (-not [string]::IsNullOrWhiteSpace($token)) {
    $headers["Authorization"] = "Bearer $token"
}

Write-Host "[SENDING] Dispatching synthetic test notification to ntfy server over HTTPS..." -ForegroundColor Gray

# 5. HTTPS Delivery Execution
try {
    if ($CustomHttpHandler) {
        $null = & $CustomHttpHandler -Url $endpointUrl -Headers $headers -Body $fixedBody
    } else {
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($fixedBody)
        $response = Invoke-RestMethod `
            -Uri $endpointUrl `
            -Method Post `
            -Headers $headers `
            -Body $bodyBytes `
            -ContentType "text/plain; charset=utf-8" `
            -TimeoutSec 15 `
            -ErrorAction Stop
    }

    Write-Host "[SUCCESS] Synthetic test notification delivered successfully (HTTP 200 OK)." -ForegroundColor Green
    Write-Host "Please check your iPhone ntfy app. You should see a notification with title '$fixedTitle'." -ForegroundColor Cyan
    exit 0
} catch {
    $statusCode = ""
    if ($_ -is [System.Management.Automation.ErrorRecord] -and $_.Exception -is [System.Net.WebException]) {
        $webEx = [System.Net.WebException]$_.Exception
        if ($webEx.Response) {
            try {
                $httpResp = [System.Net.HttpWebResponse]$webEx.Response
                $statusCode = "HTTP $([int]$httpResp.StatusCode) ($($httpResp.StatusDescription))"
            } catch { }
        }
    }

    $sanitized = Get-DeliveryTestSanitized -InputMessage $_.Exception -Config $safeConfig
    if ($statusCode) {
        Write-Host "[DELIVERY FAILED] Request failed with ${statusCode}. Diagnostic: $sanitized" -ForegroundColor Red
    } else {
        Write-Host "[DELIVERY FAILED] Connection error: $sanitized" -ForegroundColor Red
    }
    exit 1
}
