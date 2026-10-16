<#
.SYNOPSIS
    Configuration loader, validator, and log sanitizer for Windows-to-iPhone Notification Forwarder.
.DESCRIPTION
    Provides safe defaults, file parsing, validation, permission checks, and universal sanitization.
    Guarantees that raw exception messages, URLs, secret topics, and tokens are scrubbed from logs.
    Supports configurable device identity, dual-mode application filtering, and granular privacy controls.
#>

function Get-SanitizedMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $InputMessage,

        [Parameter(Mandatory = $false)]
        [hashtable]$Config = $null
    )

    if ($InputMessage -eq $null) { return "" }

    $raw = ""
    $statusCode = ""

    if ($InputMessage -is [System.Exception]) {
        $raw = $InputMessage.Message
        if ($InputMessage.InnerException -and -not [string]::IsNullOrWhiteSpace($InputMessage.InnerException.Message)) {
            $raw += " | " + $InputMessage.InnerException.Message
        }
        # Extract HTTP status code from WebException if available
        if ($InputMessage -is [System.Net.WebException] -and $InputMessage.Response) {
            try {
                $httpResp = [System.Net.HttpWebResponse]$InputMessage.Response
                $statusCode = "HTTP $([int]$httpResp.StatusCode) ($($httpResp.StatusDescription))"
            } catch { }
        }
    } else {
        $raw = [string]$InputMessage
    }

    # 1. Redact full HTTP/HTTPS URLs
    $sanitized = $raw -replace 'https?://[^\s''"<>]+', '[URL REDACTED]'

    # 2. Redact Authorization headers, Bearer tokens, and credential patterns
    $sanitized = $sanitized -replace '(?i)Bearer\s+[a-zA-Z0-9_\-\.\:]+', 'Bearer [TOKEN REDACTED]'
    $sanitized = $sanitized -replace '(?i)(token|key|secret|password|auth|authorization)\s*[:=]\s*[^\s,;]+', '$1=[REDACTED]'

    # 3. Explicitly redact configured secrets if Config is provided
    if ($Config) {
        if (-not [string]::IsNullOrWhiteSpace($Config.NtfyTopic)) {
            $sanitized = $sanitized.Replace($Config.NtfyTopic, '[TOPIC REDACTED]')
        }
        if (-not [string]::IsNullOrWhiteSpace($Config.NtfyToken)) {
            $sanitized = $sanitized.Replace($Config.NtfyToken, '[TOKEN REDACTED]')
        }
        if (-not [string]::IsNullOrWhiteSpace($Config.NtfyServer)) {
            $sanitized = $sanitized.Replace($Config.NtfyServer, '[SERVER REDACTED]')
        }
    }

    if ($statusCode) {
        return "${statusCode}: $sanitized"
    }
    return $sanitized
}

function Get-PermittedPrivacyFields {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$Config = $null
    )

    $mode = if ($Config -and $Config.PrivacyMode) { $Config.PrivacyMode } else { "TitleOnly" }

    $custom = @{
        IncludeDeviceName = $true
        IncludeAppName    = $true
        IncludeTitle      = $true
        IncludeBody       = $false
    }

    if ($Config -and $Config.CustomPrivacyFields) {
        $src = $Config.CustomPrivacyFields
        if ($src -is [hashtable]) {
            if ($null -ne $src["IncludeDeviceName"]) { $custom.IncludeDeviceName = [bool]$src["IncludeDeviceName"] }
            if ($null -ne $src["IncludeAppName"])    { $custom.IncludeAppName    = [bool]$src["IncludeAppName"] }
            if ($null -ne $src["IncludeTitle"])      { $custom.IncludeTitle      = [bool]$src["IncludeTitle"] }
            if ($null -ne $src["IncludeBody"])       { $custom.IncludeBody       = [bool]$src["IncludeBody"] }
        } elseif ($src -is [PSCustomObject]) {
            if ($null -ne $src.IncludeDeviceName) { $custom.IncludeDeviceName = [bool]$src.IncludeDeviceName }
            if ($null -ne $src.IncludeAppName)    { $custom.IncludeAppName    = [bool]$src.IncludeAppName }
            if ($null -ne $src.IncludeTitle)      { $custom.IncludeTitle      = [bool]$src.IncludeTitle }
            if ($null -ne $src.IncludeBody)       { $custom.IncludeBody       = [bool]$src.IncludeBody }
        }
    }

    switch -Regex ($mode) {
        "(?i)^TitleOnly$" {
            return @{
                Mode              = "TitleOnly"
                IncludeDeviceName = $true
                IncludeAppName    = $false
                IncludeTitle      = $true
                IncludeBody       = $false
            }
        }
        "(?i)^TitleAndApp$" {
            return @{
                Mode              = "TitleAndApp"
                IncludeDeviceName = $true
                IncludeAppName    = $true
                IncludeTitle      = $true
                IncludeBody       = $false
            }
        }
        "(?i)^TitleAndBody$" {
            return @{
                Mode              = "TitleAndBody"
                IncludeDeviceName = $true
                IncludeAppName    = $true
                IncludeTitle      = $true
                IncludeBody       = $true
            }
        }
        "(?i)^Custom$" {
            return @{
                Mode              = "Custom"
                IncludeDeviceName = [bool]$custom.IncludeDeviceName
                IncludeAppName    = [bool]$custom.IncludeAppName
                IncludeTitle      = [bool]$custom.IncludeTitle
                IncludeBody       = [bool]$custom.IncludeBody
            }
        }
        default {
            return @{
                Mode              = "TitleOnly"
                IncludeDeviceName = $true
                IncludeAppName    = $false
                IncludeTitle      = $true
                IncludeBody       = $false
            }
        }
    }
}

function Get-DefaultConfig {
    [CmdletBinding()]
    param()

    $defaultDevice = if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) { $env:COMPUTERNAME } else { "Windows-PC" }

    return @{
        DryRun                   = $true
        LiveForwardingEnabled    = $false
        DeviceName               = $defaultDevice
        PrivacyMode              = "TitleOnly"  # Options: "TitleOnly", "TitleAndApp", "TitleAndBody", "Custom"
        CustomPrivacyFields      = @{
            IncludeDeviceName = $true
            IncludeAppName    = $true
            IncludeTitle      = $true
            IncludeBody       = $false
        }
        AppFilterMode            = "Allowlist"  # Options: "Allowlist", "Blocklist", "AllWindowsNotifications"
        NtfyServer               = "https://ntfy.sh"
        NtfyTopic                = ""
        NtfyToken                = ""
        PollIntervalSeconds      = 1.5
        MaxRetries               = 3
        RetryInitialDelaySeconds = 2.0
        MaxBacklogIds            = 1000
        MaxPendingRetryQueue     = 100
        AllowedAppIds            = @(
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
        BlockedAppIds            = @()
        IgnoreAppIds             = @()
    }
}

function Protect-ConfigFileAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    try {
        if (Test-Path -Path $FilePath) {
            $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            $acl = Get-Acl -Path $FilePath
            $rule = New-Object Security.AccessControl.FileSystemAccessRule(
                $currentUser,
                "FullControl",
                "Allow"
            )
            $acl.SetAccessRule($rule)
            Set-Acl -Path $FilePath -AclObject $acl -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Verbose "Could not restrict ACL on config file: $(Get-SanitizedMessage -InputMessage $_.Exception)"
    }
}

function Load-AppConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath
    )

    $defaults = Get-DefaultConfig

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "config.json"
    }

    if (-not (Test-Path -Path $ConfigPath)) {
        Write-Host "[CONFIG] Configuration file not found. Using safe defaults (DryRun=True, LiveForwarding=False, Allowlist mode)." -ForegroundColor Yellow
        return $defaults
    }

    Protect-ConfigFileAcl -FilePath $ConfigPath

    try {
        $rawJson = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop
        $parsed = $rawJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $cleanErr = Get-SanitizedMessage -InputMessage $_.Exception -Config $defaults
        Write-Host "[CONFIG ERROR] Failed to parse config file: $cleanErr. Falling back to safe defaults." -ForegroundColor Red
        return $defaults
    }

    $config = @{}
    foreach ($key in $defaults.Keys) {
        if ($parsed.PSObject.Properties.Match($key).Count -gt 0) {
            $config[$key] = $parsed.$key
        } else {
            $config[$key] = $defaults[$key]
        }
    }

    # Strict type and boundary validations
    # 1. DeviceName validation (defaults to $env:COMPUTERNAME if empty or invalid)
    $defaultDevice = if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) { $env:COMPUTERNAME } else { "Windows-PC" }
    $rawDev = [string]$config["DeviceName"]
    if (-not [string]::IsNullOrWhiteSpace($rawDev)) {
        $cleanDev = $rawDev.Trim()
        if ($cleanDev.Length -gt 0 -and $cleanDev.Length -le 64 -and $cleanDev -notmatch '[\r\n\t]') {
            $config["DeviceName"] = $cleanDev
        } else {
            Write-Host "[CONFIG WARN] Invalid DeviceName '$rawDev'. Forcing default '$defaultDevice'." -ForegroundColor Yellow
            $config["DeviceName"] = $defaultDevice
        }
    } else {
        $config["DeviceName"] = $defaultDevice
    }

    # 2. PrivacyMode validation (case-insensitive check, normalize to TitleOnly, TitleAndApp, TitleAndBody, or Custom)
    $rawPrivacy = [string]$config["PrivacyMode"]
    if ($rawPrivacy -ieq "TitleAndBody") {
        $config["PrivacyMode"] = "TitleAndBody"
    } elseif ($rawPrivacy -ieq "TitleAndApp") {
        $config["PrivacyMode"] = "TitleAndApp"
    } elseif ($rawPrivacy -ieq "Custom") {
        $config["PrivacyMode"] = "Custom"
    } elseif ($rawPrivacy -ieq "TitleOnly") {
        $config["PrivacyMode"] = "TitleOnly"
    } else {
        if (-not [string]::IsNullOrWhiteSpace($rawPrivacy)) {
            Write-Host "[CONFIG WARN] Invalid PrivacyMode '$rawPrivacy'. Forcing safe default 'TitleOnly'." -ForegroundColor Yellow
        }
        $config["PrivacyMode"] = "TitleOnly"
    }

    # 3. CustomPrivacyFields validation
    $defaultCustom = @{
        IncludeDeviceName = $true
        IncludeAppName    = $true
        IncludeTitle      = $true
        IncludeBody       = $false
    }
    if ($parsed.PSObject.Properties.Match("CustomPrivacyFields").Count -gt 0 -and $parsed.CustomPrivacyFields) {
        $pCustom = $parsed.CustomPrivacyFields
        $config["CustomPrivacyFields"] = @{
            IncludeDeviceName = if ($null -ne $pCustom.IncludeDeviceName) { [bool]$pCustom.IncludeDeviceName } else { $true }
            IncludeAppName    = if ($null -ne $pCustom.IncludeAppName)    { [bool]$pCustom.IncludeAppName } else { $true }
            IncludeTitle      = if ($null -ne $pCustom.IncludeTitle)      { [bool]$pCustom.IncludeTitle } else { $true }
            IncludeBody       = if ($null -ne $pCustom.IncludeBody)       { [bool]$pCustom.IncludeBody } else { $false }
        }
    } else {
        $config["CustomPrivacyFields"] = $defaultCustom
    }

    # 4. AppFilterMode validation (supports Allowlist and Blocklist; AllWindowsNotifications supported as alias for Blocklist)
    $rawFilterMode = [string]$config["AppFilterMode"]
    if ($rawFilterMode -ieq "Blocklist" -or $rawFilterMode -ieq "AllWindowsNotifications") {
        $config["AppFilterMode"] = "Blocklist"
    } elseif ($rawFilterMode -ieq "Allowlist") {
        $config["AppFilterMode"] = "Allowlist"
    } else {
        if (-not [string]::IsNullOrWhiteSpace($rawFilterMode)) {
            Write-Host "[CONFIG WARN] Invalid AppFilterMode '$rawFilterMode'. Forcing safe default 'Allowlist'." -ForegroundColor Yellow
        }
        $config["AppFilterMode"] = "Allowlist"
    }

    # 5. DryRun validation
    $config["DryRun"] = [bool]$config["DryRun"]

    # 6. LiveForwardingEnabled validation
    $config["LiveForwardingEnabled"] = [bool]$config["LiveForwardingEnabled"]

    # 7. PollIntervalSeconds validation (minimum 0.5s)
    try {
        $interval = [double]$config["PollIntervalSeconds"]
        if ($interval -lt 0.5) { $interval = 0.5 }
        $config["PollIntervalSeconds"] = $interval
    } catch {
        $config["PollIntervalSeconds"] = 1.5
    }

    # 8. Retry settings
    try {
        $retries = [int]$config["MaxRetries"]
        if ($retries -lt 0) { $retries = 0 }
        if ($retries -gt 10) { $retries = 10 }
        $config["MaxRetries"] = $retries
    } catch {
        $config["MaxRetries"] = 3
    }

    try {
        $delay = [double]$config["RetryInitialDelaySeconds"]
        if ($delay -lt 0.5) { $delay = 1.0 }
        $config["RetryInitialDelaySeconds"] = $delay
    } catch {
        $config["RetryInitialDelaySeconds"] = 2.0
    }

    # 9. Queue limits
    try {
        $queueLimit = [int]$config["MaxPendingRetryQueue"]
        if ($queueLimit -lt 10) { $queueLimit = 10 }
        if ($queueLimit -gt 1000) { $queueLimit = 1000 }
        $config["MaxPendingRetryQueue"] = $queueLimit
    } catch {
        $config["MaxPendingRetryQueue"] = 100
    }

    # 10. Ensure arrays are string arrays (support AllowedAppIds, BlockedAppIds, and IgnoreAppIds)
    if ($parsed.PSObject.Properties.Match("BlockedAppIds").Count -gt 0) {
        $config["BlockedAppIds"] = @($parsed.BlockedAppIds | ForEach-Object { [string]$_ })
    } else {
        $config["BlockedAppIds"] = @()
    }
    $config["AllowedAppIds"] = @($config["AllowedAppIds"] | ForEach-Object { [string]$_ })
    $config["IgnoreAppIds"]  = @($config["IgnoreAppIds"] | ForEach-Object { [string]$_ })

    return $config
}

function Test-AppConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $errors = @()

    if ($Config.LiveForwardingEnabled -and -not $Config.DryRun) {
        if ([string]::IsNullOrWhiteSpace($Config.NtfyTopic)) {
            $errors += "Live forwarding is enabled, but NtfyTopic is empty. Please set a valid topic in config.json."
        }
        if ([string]::IsNullOrWhiteSpace($Config.NtfyServer)) {
            $errors += "NtfyServer is empty. Please configure a valid server URL (e.g. https://ntfy.sh)."
        }
    }

    return @{
        IsValid = ($errors.Count -eq 0)
        Errors  = $errors
    }
}
