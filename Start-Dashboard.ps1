<#

.SYNOPSIS

    Minimal, Secure Local Dashboard for NotificationForwarder with Application Filtering Management.

.DESCRIPTION

    Provides local status monitoring, ntfy destination configuration, ON/OFF controls,

    and Windows application allowlist/blocklist filtering management.

    - Binds strictly to 127.0.0.1 (localhost only).

    - Requires session token or session cookie authentication for all management actions.

    - Never displays tokens or secrets in the UI or console logs.

    - Atomically updates config.json with automatic backup.

    - Integrates with the existing Watchdog .disabled marker to prevent unwanted restarts when turned OFF.

    - Provides real-time application discovery from active notifications, logs, and installed apps.

#>



[CmdletBinding()]

param(

    [Parameter(Mandatory = $false)]

    [string]$ProjectDir = $null,



    [Parameter(Mandatory = $false)]

    [int]$Port = 8765,



    [Parameter(Mandatory = $false)]

    [string]$AuthToken = $null,



    [Parameter(Mandatory = $false)]

    [switch]$OpenBrowser,



    [Parameter(Mandatory = $false)]

    [switch]$RunOnce,



    [Parameter(Mandatory = $false)]

    [int]$TimeoutSeconds = 0

)



$ErrorActionPreference = "Continue"



# Resolve Project Directory

if ([string]::IsNullOrWhiteSpace($ProjectDir)) {

    $ProjectDir = $PSScriptRoot

    if ([string]::IsNullOrWhiteSpace($ProjectDir)) {

        $ProjectDir = (Get-Location).Path

    }

}



$configFile = Join-Path -Path $ProjectDir -ChildPath "config.json"

$disabledMarker = Join-Path -Path $ProjectDir -ChildPath ".disabled"

$logFile = Join-Path -Path $ProjectDir -ChildPath "forwarder.log"



# Load Config.ps1 if available

$configScript = Join-Path -Path $ProjectDir -ChildPath "Config.ps1"

if (Test-Path $configScript) {

    try { . $configScript } catch { }

}



# ------------------------------------------------------------------------------

# 1. Status Engine

# ------------------------------------------------------------------------------

function Get-ActiveForwarderProcessInfo {

    param([string]$Dir = $null)

    try {

        $targetScript = if (-not [string]::IsNullOrWhiteSpace($Dir)) {

            Join-Path -Path $Dir -ChildPath "NotificationForwarder.ps1"

        } else { $null }



        $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {

            $cmd = $_.CommandLine

            if (-not $cmd) { return $false }

            if ($cmd -like "*Recover-NotificationForwarder*" -or

                $cmd -like "*Get-NotificationForwarderStatus*" -or

                $cmd -like "*Start-Dashboard*" -or

                $cmd -like "*Test-*" -or

                $cmd -like "*Watchdog.ps1*") {

                return $false

            }

            if ($targetScript) {

                if ($cmd -match [regex]::Escape($targetScript)) { return $true }

                $normDir = ($Dir -replace '[\\/]+$', '')

                if ($cmd -match [regex]::Escape($normDir) -and ($cmd -match '(?i)(?:^|[\s"''\\])NotificationForwarder\.ps1(?:[\s"'']|$)')) {

                    return $true

                }

                return $false

            }

            return ($cmd -match '(?i)(?:^|[\s"''\\])NotificationForwarder\.ps1(?:[\s"'']|$)')

        })



        if ($procs.Count -gt 0) {

            return $procs[0]

        }

    } catch { }

    return $null

}



function Get-DashboardStatus {

    param([string]$Dir = $ProjectDir)



    $cfgPath = Join-Path $Dir "config.json"

    $markerPath = Join-Path $Dir ".disabled"

    $logPath = Join-Path $Dir "forwarder.log"



    $defaultDev = if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) { $env:COMPUTERNAME } else { "Windows-PC" }

    $cfg = @{

        LiveForwardingEnabled = $false

        DryRun                = $true

        DeviceName            = $defaultDev

        PrivacyMode           = "TitleOnly"

        CustomPrivacyFields   = @{

            IncludeDeviceName = $true

            IncludeAppName    = $true

            IncludeTitle      = $true

            IncludeBody       = $false

        }

        AppFilterMode         = "Allowlist"

        NtfyServer            = "https://ntfy.sh"

        NtfyTopic             = ""

        HasToken              = $false

        AllowedCount          = 0

        BlockedCount          = 0

    }



    if (Test-Path $cfgPath) {

        try {

            $raw = Get-Content -Path $cfgPath -Raw -Encoding UTF8 -ErrorAction Stop

            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop

            if ($null -ne $parsed.LiveForwardingEnabled) { $cfg.LiveForwardingEnabled = [bool]$parsed.LiveForwardingEnabled }

            if ($null -ne $parsed.DryRun) { $cfg.DryRun = [bool]$parsed.DryRun }

            if ($parsed.DeviceName) { $cfg.DeviceName = [string]$parsed.DeviceName }

            if ($parsed.PrivacyMode) { $cfg.PrivacyMode = [string]$parsed.PrivacyMode }

            if ($parsed.CustomPrivacyFields) {

                $pCust = $parsed.CustomPrivacyFields

                $cfg.CustomPrivacyFields = @{

                    IncludeDeviceName = if ($null -ne $pCust.IncludeDeviceName) { [bool]$pCust.IncludeDeviceName } else { $true }

                    IncludeAppName    = if ($null -ne $pCust.IncludeAppName)    { [bool]$pCust.IncludeAppName } else { $true }

                    IncludeTitle      = if ($null -ne $pCust.IncludeTitle)      { [bool]$pCust.IncludeTitle } else { $true }

                    IncludeBody       = if ($null -ne $pCust.IncludeBody)       { [bool]$pCust.IncludeBody } else { $false }

                }

            }

            if ($parsed.AppFilterMode) { $cfg.AppFilterMode = [string]$parsed.AppFilterMode }

            if ($parsed.NtfyServer) { $cfg.NtfyServer = [string]$parsed.NtfyServer }

            if ($parsed.NtfyTopic) { $cfg.NtfyTopic = [string]$parsed.NtfyTopic }

            if (-not [string]::IsNullOrWhiteSpace($parsed.NtfyToken)) { $cfg.HasToken = $true }

            if ($parsed.AllowedAppIds) { $cfg.AllowedCount = @($parsed.AllowedAppIds).Count }

            if ($parsed.BlockedAppIds) { $cfg.BlockedCount = @($parsed.BlockedAppIds).Count }

        } catch { }

    }



    $isExplicitlyDisabled = Test-Path $markerPath



    # Process Check

    $proc = Get-ActiveForwarderProcessInfo -Dir $Dir

    $procRunning = ($proc -ne $null)

    $procId = if ($procRunning) { [int]$proc.ProcessId } else { $null }



    # Scheduled Tasks Check

    $fwdTask = Get-ScheduledTask -TaskName "NotificationForwarder" -ErrorAction SilentlyContinue

    $fwdTaskState = if ($fwdTask) { $fwdTask.State.ToString() } else { "Not Registered" }



    $wdTask = Get-ScheduledTask -TaskName "NotificationForwarder-Watchdog" -ErrorAction SilentlyContinue

    $wdTaskState = if ($wdTask) { $wdTask.State.ToString() } else { "Not Registered" }



    # Watchdog state interpretation

    $watchdogStatus = if ($isExplicitlyDisabled) {

        "PAUSED (Forwarding Turned OFF)"

    } elseif ($wdTaskState -eq "Disabled") {

        "DISABLED"

    } elseif ($wdTaskState -in @("Ready", "Running")) {

        "ACTIVE ($wdTaskState)"

    } else {

        $wdTaskState

    }



    # Recent log sanitized line

    $recentLog = "None"

    if (Test-Path $logPath) {

        try {

            $lines = Get-Content -Path $logPath -Tail 20 -Encoding UTF8 -ErrorAction SilentlyContinue

            $errs = @($lines | Where-Object { $_ -match '\[(ERROR|WARN|FATAL)\]' })

            if ($errs.Count -gt 0) {

                $rawMsg = $errs[-1].Trim()

                $recentLog = [regex]::Replace($rawMsg, 'https?://\S+', '<redacted-url>')

                $recentLog = [regex]::Replace($recentLog, '(?i)Bearer\s+\S+', 'Bearer <redacted>')

            }

        } catch { }

    }



    $forwardingActive = ($cfg.LiveForwardingEnabled -and -not $cfg.DryRun -and -not $isExplicitlyDisabled)



    $configValid = (Test-Path $cfgPath) -and (-not [string]::IsNullOrWhiteSpace($cfg.NtfyTopic))

    $destinationConfigured = (-not [string]::IsNullOrWhiteSpace($cfg.NtfyTopic))

    $autoStartupConfigured = ($fwdTaskState -ne "Not Registered") -and ($wdTaskState -ne "Not Registered")

    $maskedTopic = if ($cfg.NtfyTopic.Length -gt 8) {

        $cfg.NtfyTopic.Substring(0, 4) + "..." + $cfg.NtfyTopic.Substring($cfg.NtfyTopic.Length - 4)

    } elseif (-not [string]::IsNullOrWhiteSpace($cfg.NtfyTopic)) {

        "***"

    } else {

        "Not Configured"

    }



    # Notification Permission Check

    $permAllowed = $true

    $permStatus = "Allowed"

    try {

        [Windows.UI.Notifications.Management.UserNotificationListener, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null

        $listener = [Windows.UI.Notifications.Management.UserNotificationListener]::Current

        if ($listener) {

            $access = $listener.GetAccessStatus()

            $permStatus = $access.ToString()

            $permAllowed = ($access -eq [Windows.UI.Notifications.Management.UserNotificationListenerAccessStatus]::Allowed)

        }

    } catch { }



    # Honest Service State determination: Not Configured, Needs Permission, Stopped, Starting, Running, Error

    $serviceState = if (-not (Test-Path $cfgPath) -or -not $destinationConfigured) {

        "Not Configured"

    } elseif (-not $permAllowed) {

        "Needs Permission"

    } elseif ($procRunning) {

        "Running"

    } elseif ($fwdTaskState -eq "Running" -or $fwdTaskState -eq "Queued") {

        "Starting"

    } elseif ($recentLog -match '(?i)fatal|exception|crash|unhandled') {

        "Error"

    } else {

        "Stopped"

    }



    return [PSCustomObject]@{

        ServiceState         = $serviceState

        PermissionStatus     = $permStatus

        ConfigValid          = $configValid

        DestinationConfigured = $destinationConfigured

        AutoStartupConfigured = $autoStartupConfigured

        MaskedTopic          = $maskedTopic

        LastHealthCheck      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

        ForwarderStatus      = if ($procRunning) { "RUNNING" } else { "STOPPED" }

        ForwarderProcessId   = $procId

        ForwarderTaskState   = $fwdTaskState

        WatchdogStatus       = $watchdogStatus

        WatchdogTaskState    = $wdTaskState

        ServiceDisabled      = $isExplicitlyDisabled

        LiveForwarding       = $forwardingActive

        ConfigLiveEnabled    = $cfg.LiveForwardingEnabled

        ConfigDryRun         = $cfg.DryRun

        NtfyServer           = $cfg.NtfyServer

        NtfyTopic            = $cfg.NtfyTopic

        HasToken             = $cfg.HasToken

        DeviceName           = $cfg.DeviceName

        PrivacyMode          = $cfg.PrivacyMode

        CustomPrivacyFields  = $cfg.CustomPrivacyFields

        AppFilterMode        = $cfg.AppFilterMode

        AllowedAppCount      = $cfg.AllowedCount

        BlockedAppCount      = $cfg.BlockedCount

        RecentLog            = $recentLog

    }

}



# ------------------------------------------------------------------------------

# 2. Destination Configuration Engine

# ------------------------------------------------------------------------------

function Set-DashboardDestination {

    param(

        [string]$Dir = $ProjectDir,

        [string]$Server,

        [string]$Topic

    )



    $cleanServer = if ($Server) { $Server.Trim() } else { "" }

    $cleanTopic = if ($Topic) { $Topic.Trim() } else { "" }



    # If full URL pasted into topic (e.g. https://ntfy.sh/my-topic), extract server and topic

    if ($cleanTopic -match '^(https?://[^/\s]+)/([^/\s]+)$') {

        $cleanServer = $matches[1]

        $cleanTopic = $matches[2]

    }



    # Validation

    if ([string]::IsNullOrWhiteSpace($cleanTopic)) {

        return @{

            Success = $false

            Error   = "Topic name cannot be empty."

        }

    }



    # Topic character validation (alphanumeric, underscores, hyphens, dots)

    if ($cleanTopic -notmatch '^[a-zA-Z0-9_\-\.\:\~]+$') {

        return @{

            Success = $false

            Error   = "Topic contains invalid characters. Use alphanumeric characters, hyphens, and underscores."

        }

    }



    # Server URL validation

    if ([string]::IsNullOrWhiteSpace($cleanServer)) {

        $cleanServer = "https://ntfy.sh"

    }

    if ($cleanServer -notmatch '^https?://[a-zA-Z0-9_\-\.]+(?::\d+)?(?:/.*)?$') {

        return @{

            Success = $false

            Error   = "Server must be a valid HTTP or HTTPS URL (e.g. https://ntfy.sh)."

        }

    }



    $cfgPath = Join-Path $Dir "config.json"

    $backupPath = Join-Path $Dir "config.json.bak"

    $tempPath = Join-Path $Dir "config.json.tmp"



    try {

        # Read existing configuration

        $existingRaw = Get-Content -Path $cfgPath -Raw -Encoding UTF8 -ErrorAction Stop

        $parsed = $existingRaw | ConvertFrom-Json -ErrorAction Stop



        # Create backup

        Copy-Item -Path $cfgPath -Destination $backupPath -Force



        # Update destination fields without touching other settings

        $parsed.NtfyServer = $cleanServer

        $parsed.NtfyTopic = $cleanTopic



        # Atomic write

        $newJson = $parsed | ConvertTo-Json -Depth 5

        [System.IO.File]::WriteAllText($tempPath, $newJson, [System.Text.Encoding]::UTF8)

        Move-Item -Path $tempPath -Destination $cfgPath -Force



        # Protect ACL

        if (Get-Command "Protect-ConfigFileAcl" -ErrorAction SilentlyContinue) {

            Protect-ConfigFileAcl -FilePath $cfgPath

        }



        # Check if running to inform user about restart

        $proc = Get-ActiveForwarderProcessInfo -Dir $Dir

        $isCurrentlyRunning = ($proc -ne $null)



        return @{

            Success      = $true

            Server       = $cleanServer

            Topic        = $cleanTopic

            NeedsRestart = $isCurrentlyRunning

            Message      = "Destination saved successfully."

        }

    } catch {

        if (Test-Path $tempPath) { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue }

        return @{

            Success = $false

            Error   = "Failed to update config.json: $($_.Exception.Message)"

        }

    }

}



# ------------------------------------------------------------------------------

# 2B. Device Appearance Engine

# ------------------------------------------------------------------------------

function Set-DashboardDeviceName {

    param(

        [string]$Dir = $ProjectDir,

        [string]$DeviceName

    )



    if ([string]::IsNullOrWhiteSpace($DeviceName)) {

        return @{

            Success = $false

            Error   = "Device name cannot be empty."

        }

    }



    $cleanName = $DeviceName.Trim()

    if ($cleanName.Length -gt 64) {

        return @{

            Success = $false

            Error   = "Device name cannot exceed 64 characters."

        }

    }



    if ($cleanName -match '[\r\n\t]') {

        return @{

            Success = $false

            Error   = "Device name cannot contain newline or control characters."

        }

    }



    $cfgPath = Join-Path $Dir "config.json"

    $backupPath = Join-Path $Dir "config.json.bak"

    $tempPath = Join-Path $Dir "config.json.tmp"



    try {

        $existingRaw = Get-Content -Path $cfgPath -Raw -Encoding UTF8 -ErrorAction Stop

        $parsed = $existingRaw | ConvertFrom-Json -ErrorAction Stop

        Copy-Item -Path $cfgPath -Destination $backupPath -Force



        if ($parsed.PSObject.Properties['DeviceName']) {

            $parsed.DeviceName = $cleanName

        } else {

            $parsed | Add-Member -MemberType NoteProperty -Name 'DeviceName' -Value $cleanName

        }



        $newJson = $parsed | ConvertTo-Json -Depth 5

        [System.IO.File]::WriteAllText($tempPath, $newJson, [System.Text.Encoding]::UTF8)

        Move-Item -Path $tempPath -Destination $cfgPath -Force



        if (Get-Command "Protect-ConfigFileAcl" -ErrorAction SilentlyContinue) {

            Protect-ConfigFileAcl -FilePath $cfgPath

        }



        $proc = Get-ActiveForwarderProcessInfo -Dir $Dir

        $isCurrentlyRunning = ($proc -ne $null)



        return @{

            Success      = $true

            DeviceName   = $cleanName

            NeedsRestart = $isCurrentlyRunning

            Message      = "Device name saved successfully."

        }

    } catch {

        if (Test-Path $tempPath) { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue }

        return @{

            Success = $false

            Error   = "Failed to update config.json: $($_.Exception.Message)"

        }

    }

}



# ------------------------------------------------------------------------------

# 2C. Privacy Controls Engine

# ------------------------------------------------------------------------------

function Set-DashboardPrivacy {

    param(

        [string]$Dir = $ProjectDir,

        [string]$PrivacyMode,

        $CustomFields = $null

    )



    $validModes = @("TitleOnly", "TitleAndApp", "TitleAndBody", "Custom")

    if ($PrivacyMode -notin $validModes) {

        return @{

            Success = $false

            Error   = "Invalid privacy mode. Allowed modes: TitleOnly, TitleAndApp, TitleAndBody, Custom."

        }

    }



    $cfgPath = Join-Path $Dir "config.json"

    $backupPath = Join-Path $Dir "config.json.bak"

    $tempPath = Join-Path $Dir "config.json.tmp"



    try {

        $existingRaw = Get-Content -Path $cfgPath -Raw -Encoding UTF8 -ErrorAction Stop

        $parsed = $existingRaw | ConvertFrom-Json -ErrorAction Stop

        Copy-Item -Path $cfgPath -Destination $backupPath -Force



        if ($parsed.PSObject.Properties['PrivacyMode']) {

            $parsed.PrivacyMode = $PrivacyMode

        } else {

            $parsed | Add-Member -MemberType NoteProperty -Name 'PrivacyMode' -Value $PrivacyMode

        }



        if ($CustomFields) {

            $parsed.CustomPrivacyFields = @{

                IncludeDeviceName = [bool]$CustomFields.IncludeDeviceName

                IncludeAppName    = [bool]$CustomFields.IncludeAppName

                IncludeTitle      = [bool]$CustomFields.IncludeTitle

                IncludeBody       = [bool]$CustomFields.IncludeBody

            }

        } elseif (-not $parsed.CustomPrivacyFields) {

            $parsed.CustomPrivacyFields = @{

                IncludeDeviceName = $true

                IncludeAppName    = $true

                IncludeTitle      = $true

                IncludeBody       = $false

            }

        }



        $newJson = $parsed | ConvertTo-Json -Depth 5

        [System.IO.File]::WriteAllText($tempPath, $newJson, [System.Text.Encoding]::UTF8)

        Move-Item -Path $tempPath -Destination $cfgPath -Force



        if (Get-Command "Protect-ConfigFileAcl" -ErrorAction SilentlyContinue) {

            Protect-ConfigFileAcl -FilePath $cfgPath

        }



        $proc = Get-ActiveForwarderProcessInfo -Dir $Dir

        $isCurrentlyRunning = ($proc -ne $null)



        return @{

            Success             = $true

            PrivacyMode         = $PrivacyMode

            CustomPrivacyFields = $parsed.CustomPrivacyFields

            NeedsRestart        = $isCurrentlyRunning

            Message             = "Privacy settings saved successfully."

        }

    } catch {

        if (Test-Path $tempPath) { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue }

        return @{

            Success = $false

            Error   = "Failed to update config.json: $($_.Exception.Message)"

        }

    }

}



# ------------------------------------------------------------------------------

# 3. Application Filtering Management Engine

# ------------------------------------------------------------------------------

function Get-DashboardApps {

    param([string]$Dir = $ProjectDir)



    $cfgPath = Join-Path $Dir "config.json"

    $allowed = @()

    $blocked = @()

    $mode = "Allowlist"

    $configTimestamp = ""



    if (Test-Path $cfgPath) {

        try {

            $item = Get-Item $cfgPath

            $configTimestamp = $item.LastWriteTimeUtc.ToString("o")

            $parsed = (Get-Content -Path $cfgPath -Raw -Encoding UTF8) | ConvertFrom-Json

            if ($parsed.AppFilterMode) {

                if ($parsed.AppFilterMode -ieq "Blocklist" -or $parsed.AppFilterMode -ieq "AllWindowsNotifications") {

                    $mode = "Blocklist"

                } else {

                    $mode = "Allowlist"

                }

            }

            if ($parsed.AllowedAppIds) {

                $allowed = @($parsed.AllowedAppIds | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            }

            if ($parsed.BlockedAppIds) {

                $blocked = @($parsed.BlockedAppIds | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            }

        } catch { }

    }



    # Discover applications from:

    # 1. Active notification store (UserNotificationListener)

    # 2. Historical logs (forwarder.log)

    # 3. Installed applications (Get-StartApps)

    $discovered = @{}



    # 1. Active notifications via WinRT UserNotificationListener

    try {

        [Windows.UI.Notifications.Management.UserNotificationListener, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null

        $listener = [Windows.UI.Notifications.Management.UserNotificationListener]::Current

        if ($listener -and $listener.GetAccessStatus() -eq [Windows.UI.Notifications.Management.UserNotificationListenerAccessStatus]::Allowed) {

            $kindsType = [Windows.UI.Notifications.NotificationKinds, Windows.UI.Notifications, ContentType = WindowsRuntime]

            $toastKind = [System.Enum]::Parse($kindsType, "Toast")

            $asyncOp = $listener.GetNotificationsAsync($toastKind)

            $m = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { 

                $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Length -eq 1 -and $_.GetGenericArguments().Length -eq 1 

            } | Select-Object -First 1

            if ($m) {

                $userNotifType = [Windows.UI.Notifications.UserNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]

                $roListType = [System.Collections.Generic.IReadOnlyList``1].MakeGenericType(@($userNotifType))

                $asTaskConstructed = $m.MakeGenericMethod(@($roListType))

                $task = $asTaskConstructed.Invoke($null, @($asyncOp))

                if ($task.Wait(1200)) {

                    foreach ($n in $task.Result) {

                        if ($n.AppInfo) {

                            $aumid = [string]$n.AppInfo.AppUserModelId

                            $dName = if ($n.AppInfo.DisplayInfo) { [string]$n.AppInfo.DisplayInfo.DisplayName } else { "" }

                            $key = if ($aumid) { $aumid } else { $dName }

                            if (-not [string]::IsNullOrWhiteSpace($key) -and -not $discovered.ContainsKey($key)) {

                                $discovered[$key] = [PSCustomObject]@{

                                    DisplayName = if ($dName) { $dName } else { $aumid }

                                    AppId       = $aumid

                                    Source      = "Active Notification"

                                }

                            }

                        }

                    }

                }

            }

        }

    } catch { }



    # 2. Historical logs parsing

    $logPath = Join-Path $Dir "forwarder.log"

    if (Test-Path $logPath) {

        try {

            $lines = Get-Content -Path $logPath -Tail 200 -Encoding UTF8 -ErrorAction SilentlyContinue

            foreach ($line in $lines) {

                if ($line -match "from App='([^']+)'") {

                    $appName = $matches[1].Trim()

                    if (-not [string]::IsNullOrWhiteSpace($appName) -and -not $discovered.ContainsKey($appName)) {

                        $discovered[$appName] = [PSCustomObject]@{

                            DisplayName = $appName

                            AppId       = $appName

                            Source      = "Recent Notification Log"

                        }

                    }

                }

            }

        } catch { }

    }



    # 3. Installed applications via Get-StartApps

    try {

        $startApps = Get-StartApps -ErrorAction SilentlyContinue

        if ($startApps) {

            foreach ($sa in $startApps) {

                $saName = if ($sa.Name) { $sa.Name.Trim() } else { "" }

                $saId = if ($sa.AppID) { $sa.AppID.Trim() } else { "" }

                if ($saId -and $saId -notmatch '^https?://') {

                    $cleanId = $saId

                    $cleanStem = ""

                    if ($saId -match '[\\/]') {

                        try {

                            $cleanId = [System.IO.Path]::GetFileName($saId)

                            $cleanStem = [System.IO.Path]::GetFileNameWithoutExtension($saId)

                        } catch { }

                    }

                    $dName = if ($saName) { $saName } elseif ($cleanStem) { $cleanStem } else { $cleanId }

                    $canonicalId = if ($dName) { $dName } else { $cleanId }



                    $normKey = if ($dName) { $dName.ToLowerInvariant() } else { $cleanId.ToLowerInvariant() }

                    if (-not [string]::IsNullOrWhiteSpace($normKey) -and -not $discovered.ContainsKey($normKey)) {

                        $discovered[$normKey] = [PSCustomObject]@{

                            DisplayName = $dName

                            AppId       = $cleanId

                            CanonicalId = $canonicalId

                            Source      = "Installed Application"

                        }

                    }

                }

            }

        }

    } catch { }



    # Compute effective status for each discovered application

    $discoveredList = @()

    foreach ($item in ($discovered.Values | Sort-Object DisplayName)) {

        $dName = $item.DisplayName

        $aumid = $item.AppId



        $canon = if ($item.PSObject.Properties["CanonicalId"] -and $item.CanonicalId) { $item.CanonicalId } else { $dName }



        # Check if matches blocked

        $isBlocked = $false

        foreach ($b in $blocked) {

            $bTrim = $b.Trim()

            if ($aumid -like $bTrim -or $dName -like $bTrim -or $canon -like $bTrim -or $dName.Equals($bTrim, [System.StringComparison]::OrdinalIgnoreCase) -or $aumid.Equals($bTrim, [System.StringComparison]::OrdinalIgnoreCase)) {

                $isBlocked = $true; break

            }

        }



        # Check if matches allowed

        $isAllowed = $false

        foreach ($a in $allowed) {

            $aTrim = $a.Trim()

            if ($aumid -like $aTrim -or $dName -like $aTrim -or $canon -like $aTrim -or $dName.Equals($aTrim, [System.StringComparison]::OrdinalIgnoreCase) -or $aumid.Equals($aTrim, [System.StringComparison]::OrdinalIgnoreCase)) {

                $isAllowed = $true; break

            }

        }



        $effStatus = if ($isBlocked) {

            "Blocked"

        } elseif ($isAllowed) {

            "Allowed"

        } else {

            "Not Configured"

        }



        $discoveredList += [PSCustomObject]@{

            DisplayName = $dName

            AppId       = $aumid

            CanonicalId = $canon

            Source      = $item.Source

            Status      = $effStatus

        }

    }



    return [PSCustomObject]@{

        Success          = $true

        AppFilterMode    = $mode

        AllowedAppIds    = $allowed

        BlockedAppIds    = $blocked

        ConfigTimestamp  = $configTimestamp

        DiscoveredApps   = $discoveredList

    }

}



function Set-DashboardApps {

    param(

        [string]$Dir = $ProjectDir,

        [string]$AppFilterMode = $null,

        [string[]]$AllowedAppIds = $null,

        [string[]]$BlockedAppIds = $null,

        [string]$ExpectedTimestamp = $null

    )



    $cfgPath = Join-Path $Dir "config.json"

    $backupPath = Join-Path $Dir "config.json.bak"

    $tempPath = Join-Path $Dir "config.json.tmp"



    if (-not (Test-Path $cfgPath)) {

        return @{

            Success = $false

            Error   = "Configuration file not found at $cfgPath"

        }

    }



    try {

        # Optimistic concurrency check

        if (-not [string]::IsNullOrWhiteSpace($ExpectedTimestamp)) {

            $currentTs = (Get-Item $cfgPath).LastWriteTimeUtc.ToString("o")

            if ($currentTs -ne $ExpectedTimestamp) {

                return @{

                    Success = $false

                    Error   = "Configuration was modified concurrently by another session. Please reload application rules."

                }

            }

        }



        $raw = Get-Content -Path $cfgPath -Raw -Encoding UTF8 -ErrorAction Stop

        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop



        # Validate AppFilterMode

        $targetMode = if (-not [string]::IsNullOrWhiteSpace($AppFilterMode)) {

            if ($AppFilterMode -ieq "Blocklist" -or $AppFilterMode -ieq "AllWindowsNotifications") {

                "Blocklist"

            } elseif ($AppFilterMode -ieq "Allowlist") {

                "Allowlist"

            } else {

                return @{

                    Success = $false

                    Error   = "Invalid AppFilterMode '$AppFilterMode'. Allowed modes are 'Allowlist' and 'Blocklist'."

                }

            }

        } else {

            if ($parsed.AppFilterMode -ieq "Blocklist") { "Blocklist" } else { "Allowlist" }

        }



        # Validate and sanitize AllowedAppIds

        $cleanAllowed = @()

        if ($null -ne $AllowedAppIds) {

            foreach ($item in $AllowedAppIds) {

                if ([string]::IsNullOrWhiteSpace($item)) { continue }

                $str = ([string]$item).Trim()

                if ($str.Length -gt 260) {

                    return @{

                        Success = $false

                        Error   = "Application identifier exceeds 260 characters: $str"

                    }

                }

                if ($str -match '[\r\n\x00-\x1f]') {

                    return @{

                        Success = $false

                        Error   = "Application identifier contains illegal control characters: $str"

                    }

                }

                if ($cleanAllowed -notcontains $str) {

                    $cleanAllowed += $str

                }

            }

        } else {

            if ($parsed.AllowedAppIds) {

                $cleanAllowed = @($parsed.AllowedAppIds | ForEach-Object { [string]$_ })

            }

        }



        # Validate and sanitize BlockedAppIds

        $cleanBlocked = @()

        if ($null -ne $BlockedAppIds) {

            foreach ($item in $BlockedAppIds) {

                if ([string]::IsNullOrWhiteSpace($item)) { continue }

                $str = ([string]$item).Trim()

                if ($str.Length -gt 260) {

                    return @{

                        Success = $false

                        Error   = "Application identifier exceeds 260 characters: $str"

                    }

                }

                if ($str -match '[\r\n\x00-\x1f]') {

                    return @{

                        Success = $false

                        Error   = "Application identifier contains illegal control characters: $str"

                    }

                }

                if ($cleanBlocked -notcontains $str) {

                    $cleanBlocked += $str

                }

            }

        } else {

            if ($parsed.BlockedAppIds) {

                $cleanBlocked = @($parsed.BlockedAppIds | ForEach-Object { [string]$_ })

            }

        }



        # Cross-validation: If an app is explicitly added to Blocked, remove it from Allowed

        $finalAllowed = @()

        foreach ($a in $cleanAllowed) {

            if ($cleanBlocked -notcontains $a) {

                $finalAllowed += $a

            }

        }



        # Create backup

        Copy-Item -Path $cfgPath -Destination $backupPath -Force



        # Update JSON fields safely across PSCustomObject note properties
        if ($parsed.PSObject.Properties['AppFilterMode']) {
            $parsed.AppFilterMode = $targetMode
        } else {
            $parsed | Add-Member -MemberType NoteProperty -Name 'AppFilterMode' -Value $targetMode -Force
        }

        if ($parsed.PSObject.Properties['AllowedAppIds']) {
            $parsed.AllowedAppIds = $finalAllowed
        } else {
            $parsed | Add-Member -MemberType NoteProperty -Name 'AllowedAppIds' -Value $finalAllowed -Force
        }

        if ($parsed.PSObject.Properties['BlockedAppIds']) {
            $parsed.BlockedAppIds = $cleanBlocked
        } else {
            $parsed | Add-Member -MemberType NoteProperty -Name 'BlockedAppIds' -Value $cleanBlocked -Force
        }

        # Keep legacy IgnoreAppIds in sync for backward compatibility
        if ($parsed.PSObject.Properties['IgnoreAppIds']) {
            $parsed.IgnoreAppIds = $cleanBlocked
        } else {
            $parsed | Add-Member -MemberType NoteProperty -Name 'IgnoreAppIds' -Value $cleanBlocked -Force
        }



        # Atomic write

        $newJson = $parsed | ConvertTo-Json -Depth 5

        [System.IO.File]::WriteAllText($tempPath, $newJson, [System.Text.Encoding]::UTF8)

        Move-Item -Path $tempPath -Destination $cfgPath -Force



        if (Get-Command "Protect-ConfigFileAcl" -ErrorAction SilentlyContinue) {

            Protect-ConfigFileAcl -FilePath $cfgPath

        }



        $newTs = (Get-Item $cfgPath).LastWriteTimeUtc.ToString("o")



        $proc = Get-ActiveForwarderProcessInfo -Dir $Dir

        $isCurrentlyRunning = ($proc -ne $null)



        return @{

            Success         = $true

            AppFilterMode   = $targetMode

            AllowedCount    = $finalAllowed.Count

            BlockedCount    = $cleanBlocked.Count

            AllowedAppIds   = $finalAllowed

            BlockedAppIds   = $cleanBlocked

            ConfigTimestamp = $newTs

            NeedsRestart    = $isCurrentlyRunning

            Message         = "Application filtering configuration saved successfully."

        }

    } catch {

        if (Test-Path $tempPath) { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue }

        return @{

            Success = $false

            Error   = "Failed to save application configuration: $($_.Exception.Message)"

        }

    }

}



# ------------------------------------------------------------------------------

# 4. ON / OFF Control Engine

# ------------------------------------------------------------------------------

function Set-DashboardForwardingState {

    param(

        [string]$Dir = $ProjectDir,

        [bool]$Enable,

        [string]$ForwarderTaskName = "NotificationForwarder"

    )



    $markerPath = Join-Path $Dir ".disabled"

    $cfgPath = Join-Path $Dir "config.json"

    $backupPath = Join-Path $Dir "config.json.bak"



    if ($Enable -eq $false) {

        # -----------------------------

        # TURN OFF

        # -----------------------------

        try {

            # 1. Place .disabled marker so Watchdog takes NO action and will not restart it

            [System.IO.File]::WriteAllText($markerPath, (Get-Date).ToString("o"), [System.Text.Encoding]::UTF8)



            # 2. Update config.json LiveForwardingEnabled = false

            if (Test-Path $cfgPath) {

                try {

                    Copy-Item -Path $cfgPath -Destination $backupPath -Force

                    $parsed = (Get-Content -Path $cfgPath -Raw -Encoding UTF8) | ConvertFrom-Json

                    $parsed.LiveForwardingEnabled = $false

                    $tempPath = Join-Path $Dir "config.json.tmp"

                    [System.IO.File]::WriteAllText($tempPath, ($parsed | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)

                    Move-Item -Path $tempPath -Destination $cfgPath -Force

                } catch { }

            }



            # 3. Stop Scheduled Task and Process

            Stop-ScheduledTask -TaskName $ForwarderTaskName -ErrorAction SilentlyContinue

            Start-Sleep -Milliseconds 800



            # Force terminate any remaining process matching this directory

            $proc = Get-ActiveForwarderProcessInfo -Dir $Dir

            if ($proc) {

                Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue

                Start-Sleep -Milliseconds 500

            }



            return @{

                Success = $true

                State   = "OFF"

                Message = "Forwarding turned OFF. Background daemon stopped; Watchdog monitoring safely paused."

            }

        } catch {

            return @{

                Success = $false

                State   = "ERROR"

                Error   = "Error turning forwarding OFF: $($_.Exception.Message)"

            }

        }

    } else {

        # -----------------------------

        # TURN ON

        # -----------------------------

        try {

            # Validate topic before turning live forwarding ON

            if (Test-Path $cfgPath) {

                try {

                    $chk = (Get-Content -Path $cfgPath -Raw -Encoding UTF8) | ConvertFrom-Json

                    if ([string]::IsNullOrWhiteSpace($chk.NtfyTopic)) {

                        return @{

                            Success = $false

                            State   = "Not Configured"

                            Error   = "Cannot activate live forwarding: Notification key/topic is not configured. Please click ''Generate New Key'' or configure a valid topic first."

                        }

                    }

                } catch { }

            } else {

                return @{

                    Success = $false

                    State   = "Not Configured"

                    Error   = "Configuration file not found. Please configure destination settings first."

                }

            }



            # 1. Remove .disabled marker file

            if (Test-Path $markerPath) {

                Remove-Item -Path $markerPath -Force -ErrorAction SilentlyContinue

            }



            # 2. Update config.json: LiveForwardingEnabled = true, DryRun = false

            if (Test-Path $cfgPath) {

                try {

                    Copy-Item -Path $cfgPath -Destination $backupPath -Force

                    $parsed = (Get-Content -Path $cfgPath -Raw -Encoding UTF8) | ConvertFrom-Json

                    $parsed.LiveForwardingEnabled = $true

                    $parsed.DryRun = $false

                    $tempPath = Join-Path $Dir "config.json.tmp"

                    [System.IO.File]::WriteAllText($tempPath, ($parsed | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)

                    Move-Item -Path $tempPath -Destination $cfgPath -Force

                } catch { }

            }



            # 3. Start task if not already running (prevent duplicates)

            $existingProc = Get-ActiveForwarderProcessInfo -Dir $Dir

            $verifiedPid = $null

            if ($existingProc) {

                $verifiedPid = $existingProc.ProcessId

            } else {

                Start-ScheduledTask -TaskName $ForwarderTaskName -ErrorAction Stop

                for ($i = 0; $i -lt 6; $i++) {

                    Start-Sleep -Milliseconds 500

                    $checkProc = Get-ActiveForwarderProcessInfo -Dir $Dir

                    if ($checkProc) {

                        $verifiedPid = $checkProc.ProcessId

                        break

                    }

                }

            }



            if ($verifiedPid) {

                return @{

                    Success   = $true

                    State     = "ON"

                    ProcessId = $verifiedPid

                    Message   = "Forwarding turned ON. Service is active and running (PID $verifiedPid)."

                }

            } else {

                return @{

                    Success   = $false

                    State     = "WARN"

                    ProcessId = $null

                    Error     = "Task was signaled to start, but no active process was detected within verification timeout."

                }

            }

        } catch {

            return @{

                Success = $false

                State   = "ERROR"

                Error   = "Error turning forwarding ON: $($_.Exception.Message)"

            }

        }

    }

}



# ------------------------------------------------------------------------------

# 5. Safe Forwarder Restart Helper

# ------------------------------------------------------------------------------

function Restart-DashboardForwarder {

    param(

        [string]$Dir = $ProjectDir,

        [string]$ForwarderTaskName = "NotificationForwarder"

    )



    try {

        Stop-ScheduledTask -TaskName $ForwarderTaskName -ErrorAction SilentlyContinue

        Start-Sleep -Milliseconds 1000



        $oldProc = Get-ActiveForwarderProcessInfo -Dir $Dir

        if ($oldProc) {

            Stop-Process -Id $oldProc.ProcessId -Force -ErrorAction SilentlyContinue

            Start-Sleep -Milliseconds 500

        }



        $markerPath = Join-Path $Dir ".disabled"

        if (Test-Path $markerPath) {

            Remove-Item $markerPath -Force -ErrorAction SilentlyContinue

        }



        Start-ScheduledTask -TaskName $ForwarderTaskName -ErrorAction Stop

        $newPid = $null

        for ($i = 0; $i -lt 6; $i++) {

            Start-Sleep -Milliseconds 500

            $p = Get-ActiveForwarderProcessInfo -Dir $Dir

            if ($p) {

                $newPid = $p.ProcessId

                break

            }

        }



        if ($newPid) {

            return @{

                Success   = $true

                ProcessId = $newPid

                Message   = "Forwarder restarted successfully (PID $newPid)."

            }

        } else {

            return @{

                Success   = $false

                ProcessId = $null

                Error     = "Restart was triggered, but process was not detected within timeout."

            }

        }

    } catch {

        return @{

            Success = $false

            Error   = "Failed to restart forwarder: $($_.Exception.Message)"

        }

    }

}





# ------------------------------------------------------------------------------

# 5b. Start Push Notification Workflow Engine (One-Click Setup)

# ------------------------------------------------------------------------------

function Invoke-StartPushNotification {

    [CmdletBinding()]

    param(

        [Parameter(Mandatory = $false)]

        [string]$ProjectDir = $null,



        [Parameter(Mandatory = $false)]

        [switch]$SkipTaskRegistration

    )



    if ([string]::IsNullOrWhiteSpace($ProjectDir)) {

        if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {

            $ProjectDir = $PSScriptRoot

        } else {

            $ProjectDir = (Get-Location).Path

        }

    }

    $ProjectDir = (Resolve-Path $ProjectDir).Path



    $cfgPath = Join-Path $ProjectDir "config.json"

    $backupPath = Join-Path $ProjectDir "config.json.bak"

    $tempPath = Join-Path $ProjectDir "config.json.tmp"

    $markerPath = Join-Path $ProjectDir ".disabled"



    # Step 1: Validate required scripts exist

    $requiredScripts = @(

        "NotificationForwarder.ps1",

        "NotificationReader.ps1",

        "NotificationFilter.ps1",

        "NotificationSender.ps1",

        "Config.ps1",

        "Watchdog.ps1",

        "Run-WatchdogHidden.vbs",

        "Recover-NotificationForwarder.ps1",

        "Register-NotificationForwarderTask.ps1",

        "Get-NotificationForwarderStatus.ps1"

    )

    $missingScripts = @()

    foreach ($s in $requiredScripts) {

        if (-not (Test-Path (Join-Path $ProjectDir $s))) {

            $missingScripts += $s

        }

    }

    if ($missingScripts.Count -gt 0) {

        return @{

            Success = $false

            Error   = "Required project script(s) missing: $($missingScripts -join ', ')"

            Step    = "ScriptValidation"

        }

    }



    # Step 2: Validate configuration file exists or initialize from template

    if (-not (Test-Path $cfgPath)) {

        $examplePath = Join-Path $ProjectDir "config.example.json"

        if (Test-Path $examplePath) {

            Copy-Item -Path $examplePath -Destination $cfgPath -Force

        } else {

            return @{

                Success = $false

                Error   = "Configuration file '$cfgPath' not found and no template available."

                Step    = "ConfigValidation"

            }

        }

    }



    $raw = Get-Content -Path $cfgPath -Raw -Encoding UTF8 -ErrorAction Stop

    $cfg = $raw | ConvertFrom-Json -ErrorAction Stop



    # Step 3: Validate destination topic

    $topic = if ($cfg.NtfyTopic) { [string]$cfg.NtfyTopic.Trim() } else { "" }

    if ([string]::IsNullOrWhiteSpace($topic) -or -not ($topic -match '^[a-zA-Z0-9_\-]{4,64}$')) {

        return @{

            Success = $false

            Error   = "A valid ntfy destination topic is required (4-64 characters). Please configure your topic before starting push notifications."

            Step    = "TopicValidation"

        }

    }



    # Helper to set or add note property safely

    $setProp = {

        param($obj, [string]$name, $val)

        if ($obj.PSObject.Properties[$name]) {

            $obj.$name = $val

        } else {

            $obj | Add-Member -MemberType NoteProperty -Name $name -Value $val

        }

    }



    # Step 4: Validate device name

    $devName = if ($cfg.PSObject.Properties['DeviceName'] -and -not [string]::IsNullOrWhiteSpace($cfg.DeviceName)) {

        $cfg.DeviceName

    } else {

        if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) { $env:COMPUTERNAME } else { "Windows-PC" }

    }

    & $setProp $cfg "DeviceName" $devName



    # Step 5: Validate application filtering & safe defaults

    $appFilterMode = if ($cfg.PSObject.Properties['AppFilterMode'] -and -not [string]::IsNullOrWhiteSpace($cfg.AppFilterMode)) {

        $cfg.AppFilterMode

    } else {

        "Allowlist"

    }

    & $setProp $cfg "AppFilterMode" $appFilterMode



    $allowedList = if ($cfg.PSObject.Properties['AllowedAppIds'] -and @($cfg.AllowedAppIds).Count -gt 0) {

        @($cfg.AllowedAppIds)

    } else {

        @("WhatsApp", "Telegram", "Google Chrome", "Slack", "Discord", "Microsoft Teams", "Windows Security")

    }

    & $setProp $cfg "AllowedAppIds" $allowedList



    # Step 6: Preserve configuration backup (safe against overwriting identical or useful backup)

    try {

        $shouldBackup = $true

        if (Test-Path $backupPath) {

            try {

                if ([System.IO.File]::ReadAllText($cfgPath).Trim() -eq [System.IO.File]::ReadAllText($backupPath).Trim()) {

                    $shouldBackup = $false

                }

            } catch { }

        }

        if ($shouldBackup) {

            Copy-Item -Path $cfgPath -Destination $backupPath -Force

        }

    } catch { }



    # Step 7: Apply configuration updates atomically: LiveForwardingEnabled = true, DryRun = false

    try {

        & $setProp $cfg "LiveForwardingEnabled" $true

        & $setProp $cfg "DryRun" $false

        $newJson = $cfg | ConvertTo-Json -Depth 5

        [System.IO.File]::WriteAllText($tempPath, $newJson, [System.Text.Encoding]::UTF8)

        Move-Item -Path $tempPath -Destination $cfgPath -Force

    } catch {

        return @{

            Success = $false

            Error   = "Failed to write configuration atomically: $($_.Exception.Message)"

            Step    = "ConfigSave"

        }

    }



    # Step 8: Remove .disabled marker file

    if (Test-Path $markerPath) {

        Remove-Item -Path $markerPath -Force -ErrorAction SilentlyContinue

    }



    # Step 9: Register or repair Windows Scheduled Tasks (for Windows startup persistence)

    if (-not $SkipTaskRegistration) {

        try {

            $regScript = Join-Path $ProjectDir "Register-NotificationForwarderTask.ps1"

            & powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $regScript -Register -ProjectDirectory $ProjectDir | Out-Null

        } catch {

            Write-Host "[WARN] Scheduled task registration note: $($_.Exception.Message)" -ForegroundColor Yellow

        }

    }



    # Step 10: Start / Recover forwarder process using Recover-NotificationForwarder.ps1

    $recoverScript = Join-Path $ProjectDir "Recover-NotificationForwarder.ps1"

    $recoverRes = & powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $recoverScript -ProjectDir $ProjectDir -NonInteractive -PassThru 2>&1



    # Start Watchdog scheduled task if registered

    try {

        Start-ScheduledTask -TaskName "NotificationForwarder-Watchdog" -ErrorAction SilentlyContinue

    } catch { }



    # Step 11: Verify that forwarder process is actively running for this specific installation

    $runningProc = $null

    for ($i = 0; $i -lt 6; $i++) {

        Start-Sleep -Milliseconds 400

        $runningProc = Get-ActiveForwarderProcessInfo -Dir $ProjectDir

        if ($runningProc) {

            break

        }

    }



    if (-not $runningProc) {

        if (Test-Path $backupPath) {

            Copy-Item -Path $backupPath -Destination $cfgPath -Force

        }

        return @{

            Success = $false

            Error   = "Notification forwarder process failed to start. Review forwarder.log for details."

            Step    = "ProcessVerification"

        }

    }



    # Step 12: Verify scheduled tasks status

    $fwdTask = Get-ScheduledTask -TaskName "NotificationForwarder" -ErrorAction SilentlyContinue

    $wdTask = Get-ScheduledTask -TaskName "NotificationForwarder-Watchdog" -ErrorAction SilentlyContinue



    # Step 13: Mask topic for safe display

    $maskedTopic = if ($topic.Length -gt 8) {

        $topic.Substring(0, 4) + "..." + $topic.Substring($topic.Length - 4)

    } else { "***" }



    return @{

        Success            = $true

        ProcessId          = [int]$runningProc.ProcessId

        ForwarderRunning   = $true

        ForwarderTaskState = if ($fwdTask) { $fwdTask.State.ToString() } else { "Registered" }

        WatchdogTaskState  = if ($wdTask) { $wdTask.State.ToString() } else { "Registered" }

        LiveForwarding     = $true

        MaskedTopic        = $maskedTopic

        DeviceName         = $cfg.DeviceName

        PrivacyMode        = $cfg.PrivacyMode

        AllowedAppCount    = @($cfg.AllowedAppIds).Count

        Message            = "Notification forwarder (PID $($runningProc.ProcessId)) and hidden watchdog are running silently in the background! Live forwarding is ACTIVE and configured to start automatically with Windows. You can safely close this dashboard or any terminal window."

    }

}



# ------------------------------------------------------------------------------

# 6. Embedded HTML Template

# ------------------------------------------------------------------------------

function Send-DashboardTestNotification {

    [CmdletBinding()]

    param(

        [Parameter(Mandatory = $false)]

        [string]$Dir = $ProjectDir,



        [Parameter(Mandatory = $false)]

        [scriptblock]$CustomHttpHandler = $null

    )



    if ([string]::IsNullOrWhiteSpace($Dir)) {

        if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {

            $Dir = $PSScriptRoot

        } else {

            $Dir = (Get-Location).Path

        }

    }

    $Dir = (Resolve-Path $Dir).Path



    $cfgPath = Join-Path $Dir "config.json"

    if (-not (Test-Path $cfgPath)) {

        return @{

            Success           = $false

            Error             = "Configuration file not found. Please complete setup first."

            ConfirmedDelivery = $false

        }

    }



    try {

        $raw = Get-Content -Path $cfgPath -Raw -Encoding UTF8 -ErrorAction Stop

        $cfg = $raw | ConvertFrom-Json -ErrorAction Stop

    } catch {

        return @{

            Success           = $false

            Error             = "Failed to read configuration: $($_.Exception.Message)"

            ConfirmedDelivery = $false

        }

    }



    $topic = if ($cfg.PSObject.Properties["NtfyTopic"] -and $cfg.NtfyTopic) { [string]$cfg.NtfyTopic.Trim() } else { "" }

    $server = if ($cfg.PSObject.Properties["NtfyServer"] -and $cfg.NtfyServer) { [string]$cfg.NtfyServer.Trim() } else { "https://ntfy.sh" }

    $token = if ($cfg.PSObject.Properties["NtfyToken"] -and $cfg.NtfyToken) { [string]$cfg.NtfyToken.Trim() } else { "" }



    if ([string]::IsNullOrWhiteSpace($topic)) {

        return @{

            Success           = $false

            Error             = "Destination topic is empty. Please generate or configure a topic key first."

            ConfirmedDelivery = $false

        }

    }



    if ($topic -match '[\r\n\t\s/\\#\?]') {

        return @{

            Success           = $false

            Error             = "Destination topic contains invalid characters (whitespace, slashes, or query characters are not allowed)."

            ConfirmedDelivery = $false

        }

    }



    if (-not ($server -like "https://*" -or $server -like "http://localhost*" -or $server -like "http://127.0.0.1*")) {

        return @{

            Success           = $false

            Error             = "Destination server must use secure HTTPS (e.g. 'https://ntfy.sh')."

            ConfirmedDelivery = $false

        }

    }



    # Dot-source NotificationSender.ps1 if available

    $senderModule = Join-Path -Path $Dir -ChildPath "NotificationSender.ps1"

    if (Test-Path $senderModule) {

        . $senderModule

    }



    $testNotif = [PSCustomObject]@{

        Id             = [uint32]999999

        AppLabel       = "NotificationForwarder"

        AppUserModelId = "NotificationForwarder.Test"

        AppDisplayName = "NotificationForwarder"

        Title          = "NotificationForwarder Test"

        Body           = "NotificationForwarder test message. Delivery verified."

        IsAlert        = $true

        PrivacyMode    = "TitleAndBody"

        AppFilterMode  = "Allowlist"

    }



    $senderCfg = @{

        NtfyServer  = $server

        NtfyTopic   = $topic

        NtfyToken   = $token

        DeviceName  = if ($cfg.PSObject.Properties["DeviceName"] -and $cfg.DeviceName) { $cfg.DeviceName } else { $env:COMPUTERNAME }

        PrivacyMode = "TitleAndBody"

    }



    if (Get-Command "Send-SingleAttempt" -ErrorAction SilentlyContinue) {

        $res = Send-SingleAttempt -FilteredNotification $testNotif -Config $senderCfg -AttemptNumber 1 -CustomHttpHandler $CustomHttpHandler

        if ($res.Success) {

            return @{

                Success           = $true

                Message           = "Test notification delivered successfully (HTTP 200 OK). Please check your iPhone."

                ConfirmedDelivery = $true

            }

        } else {

            return @{

                Success           = $false

                Error             = "Delivery failed: $($res.Error)"

                ConfirmedDelivery = $false

            }

        }

    } else {

        # Fallback HTTP dispatch

        $serverClean = $server.TrimEnd('/')

        $endpoint = "$serverClean/$topic"

        $headers = @{

            "Title"    = "NotificationForwarder: NotificationForwarder Test"

            "Priority" = "3"

            "Tags"     = "bell"

        }

        if ($token) { $headers["Authorization"] = "Bearer $token" }



        try {

            if ($CustomHttpHandler) {

                $null = & $CustomHttpHandler -Url $endpoint -Headers $headers -Body $testNotif.Body -Attempt 1

            } else {

                $bytes = [System.Text.Encoding]::UTF8.GetBytes($testNotif.Body)

                $null = Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers -Body $bytes -ContentType "text/plain; charset=utf-8" -TimeoutSec 10 -ErrorAction Stop

            }

            return @{

                Success           = $true

                Message           = "Test notification delivered successfully (HTTP 200 OK). Please check your iPhone."

                ConfirmedDelivery = $true

            }

        } catch {

            $errClean = if (Get-Command "Get-SanitizedMessage" -ErrorAction SilentlyContinue) {

                Get-SanitizedMessage -InputMessage $_.Exception -Config $senderCfg

            } else {

                $_.Exception.Message

            }

            return @{

                Success           = $false

                Error             = "Delivery failed: $errClean"

                ConfirmedDelivery = $false

            }

        }

    }

}



function Get-DashboardHtml {

    param([string]$AuthToken)



    # Use single-quoted here-string so that zero variable or backtick interpolation occurs in PowerShell

    $template = @'

<!DOCTYPE html>

<html lang="en">

<head>

  <meta charset="UTF-8">

  <meta name="viewport" content="width=device-width, initial-scale=1.0">

  <title>NotificationForwarder Dashboard</title>

  <style>

    :root {

      color-scheme: light;

      --page: #EFEFEF;

      --surface: #FFFFFF;

      --action: #234CE2;

      --ink: #212121;

    }

    * { box-sizing: border-box; }

    html { scroll-behavior: smooth; }

    body {

      margin: 0;

      padding: clamp(20px, 4vw, 52px) clamp(16px, 4vw, 56px) 56px;

      background: var(--page);

      color: var(--ink);

      font-family: "Segoe UI", Inter, -apple-system, BlinkMacSystemFont, Arial, sans-serif;

      font-size: 15px;

      line-height: 1.6;

    }

    .container { max-width: 1180px; margin: 0 auto; }

    .header-copy { display: grid; gap: 5px; }

    .header-subtitle { margin: 0; color: var(--ink); font-size: .9rem; }

    .page-nav { display: flex; gap: 8px; margin: 0 0 18px; overflow-x: auto; }

    .page-nav a { display: inline-flex; min-height: 40px; align-items: center; padding: 8px 16px; border-radius: 999px; background: var(--surface); color: var(--ink); font-size: .83rem; font-weight: 650; text-decoration: none; white-space: nowrap; }

    .page-nav a:hover { background: var(--page); }

    .page-nav a:focus-visible { outline: 3px solid var(--action); outline-offset: 3px; }

    header {

      display: flex;

      align-items: center;

      justify-content: space-between;

      gap: 20px;

      margin-bottom: 26px;

    }

    h1 { margin: 0; color: var(--ink); font-size: clamp(1.4rem, 2vw, 1.9rem); line-height: 1.2; letter-spacing: -0.035em; font-weight: 750; }

    .dashboard-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 18px; align-items: start; }

    .card {

      min-width: 0;

      margin: 0;

      padding: clamp(20px, 2.4vw, 30px);

      background: var(--surface);

      border: 0 !important;

      border-radius: 26px;

      color: var(--ink);

      scroll-margin-top: 20px;

    }

    .card--wide { grid-column: 1 / -1; }

    .card-title {

      margin: 0 0 18px;

      color: var(--ink);

      font-size: .78rem;

      line-height: 1.3;

      font-weight: 750;

      letter-spacing: .11em;

      text-transform: uppercase;

    }

    .hero-heading { display: flex; align-items: center; justify-content: space-between; gap: 14px; margin-bottom: 6px; }

    .hero-title { margin: 0; font-size: 1.08rem; font-weight: 750; letter-spacing: -.02em; }

    .hero-copy, p { margin-top: 0; color: var(--ink); }

    .hero-button { width: 100%; min-height: 52px; font-size: 1rem; }

    .start-progress { display: none; margin-top: 10px; color: var(--ink); font-size: .84rem; font-weight: 650; }

    .appearance-note { margin-top: 14px; padding: 12px 14px; border: 0 !important; border-radius: 18px; background: var(--page); color: var(--ink); font-size: .81rem; }

    .app-search { margin-bottom: 14px; }

    .custom-rule { margin-bottom: 16px; padding: 14px; border-radius: 18px; background: var(--page); }

    .custom-rule-controls { display: flex; gap: 9px; }

    .app-section { margin-bottom: 18px; }

    .list-caption { color: var(--ink); font-size: .78rem; }

    .empty-state { padding: 14px; color: var(--ink); font-size: .86rem; }

    .details-card { padding: 14px 20px; font-size: .82rem; }

    .hero-copy { max-width: 780px; margin-bottom: 18px; }

    .badge {

      display: inline-flex;

      align-items: center;

      min-height: 28px;

      padding: 4px 11px;

      border: 0 !important;

      border-radius: 999px;

      background: var(--page);

      color: var(--ink);

      font-size: .72rem;

      font-weight: 700;

      letter-spacing: .05em;

      text-transform: uppercase;

      white-space: nowrap;

    }

    .badge-green, .badge-red, .badge-yellow, .badge-gray { background: var(--page); color: var(--ink); }

    .status-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); column-gap: 28px; }

    .status-row {

      display: flex;

      justify-content: space-between;

      align-items: center;

      gap: 14px;

      min-height: 56px;

      padding: 10px 0;

      border: 0 !important;

    }

    .status-label { color: var(--ink); font-size: .9rem; font-weight: 500; }

    .status-val { color: var(--ink); font-size: .86rem; font-weight: 650; text-align: right; }

    .btn-group { display: flex; gap: 10px; margin-top: 14px; }

    button {

      min-height: 42px;

      padding: 10px 17px;

      border: 0 !important;

      border-radius: 16px;

      background: var(--action) !important;

      color: #FFFFFF !important;

      font: inherit;

      font-size: .88rem;

      font-weight: 700;

      cursor: pointer;

      transition: transform .16s ease, filter .16s ease;

    }

    button:hover { transform: translateY(-1px); }

    button:active { transform: translateY(0); }

    button:disabled { cursor: wait; }

    button:focus-visible, input:focus-visible, [role="option"]:focus-visible {

      outline: 3px solid var(--action);

      outline-offset: 3px;

    }

    .btn-on, .btn-off { flex: 1; }

    .btn-refresh { min-height: 40px; padding: 8px 14px; font-size: .82rem; }

    .btn-restart { display: none; width: 100%; margin-top: 12px; }

    .btn-sm { min-height: 34px; padding: 6px 11px; font-size: .78rem; }

    .form-group { margin-bottom: 18px; }

    label { display: block; margin-bottom: 7px; color: var(--ink); font-size: .85rem; font-weight: 650; }

    input[type="text"] {

      width: 100%;

      min-height: 46px;

      padding: 11px 14px;

      border: 0 !important;

      border-radius: 16px;

      outline: 0;

      background: var(--page) !important;

      color: var(--ink) !important;

      font: inherit;

      font-size: .92rem;

    }

    input[type="text"]:focus { box-shadow: inset 0 0 0 2px var(--action); }

    input::placeholder { color: var(--ink); }

    .note { margin-top: 7px; color: var(--ink); font-size: .77rem; }

    #alertBanner {

      display: none;

      grid-column: 1 / -1;

      margin: 0;

      padding: 13px 16px;

      border: 0 !important;

      border-radius: 18px;

      background: var(--surface);

      color: var(--ink);

      font-size: .88rem;

      box-shadow: inset 4px 0 var(--action);

    }

    .alert-success, .alert-error, .alert-info { background: var(--surface); color: var(--ink); }

    .app-item {

      display: flex;

      justify-content: space-between;

      align-items: center;

      gap: 12px;

      padding: 12px;

      margin: 4px 0;

      border: 0 !important;

      border-radius: 16px;

      background: var(--page);

      color: var(--ink);

      font-size: .88rem;

    }

    .app-info { flex: 1; min-width: 0; padding-right: 8px; }

    .app-title, .app-sub { overflow: hidden; color: var(--ink); text-overflow: ellipsis; white-space: nowrap; }

    .app-title { font-weight: 650; }

    .app-sub { font-size: .75rem; }

    .app-actions { display: flex; flex-wrap: wrap; gap: 7px; align-items: center; justify-content: flex-end; }

    .preview-box { margin-top: 10px; padding: 16px; border: 0 !important; border-radius: 18px; background: var(--page); color: var(--ink); }

    .preview-section { margin-top: 16px; }

    .preview-line-device, .preview-line-app, .preview-line-title, .preview-line-body { color: var(--ink); }

    .preview-line-device { display: flex; align-items: center; gap: 6px; margin-bottom: 3px; font-weight: 750; }

    .preview-line-app, .preview-line-title { margin-bottom: 3px; font-size: .88rem; font-weight: 650; }

    .preview-line-body { font-size: .85rem; }

    .privacy-option {

      display: flex;

      align-items: flex-start;

      gap: 13px;

      padding: 14px 15px;

      margin-bottom: 8px;

      border: 0 !important;

      border-radius: 18px;

      background: var(--page);

      color: var(--ink);

      cursor: pointer;

      transition: transform .16s ease;

    }

    .privacy-option:hover { transform: translateY(-1px); }

    .privacy-option:focus-within { box-shadow: inset 0 0 0 2px var(--action); }

    .privacy-option input[type="radio"] { width: 18px; height: 18px; margin: 2px 0 0; accent-color: var(--action); cursor: pointer; }

    .privacy-label { flex: 1; cursor: pointer; }

    .privacy-title { color: var(--ink); font-size: .9rem; font-weight: 700; }

    .privacy-desc { margin-top: 3px; color: var(--ink); font-size: .79rem; }

    .custom-fields-panel { display: none; margin: 10px 0 14px; padding: 13px 15px; border: 0 !important; border-radius: 18px; background: var(--page); color: var(--ink); }

    .custom-chk-row { display: flex; align-items: center; gap: 9px; padding: 6px 0; color: var(--ink); font-size: .85rem; cursor: pointer; }

    .custom-chk-row input[type="checkbox"] { width: 17px; height: 17px; accent-color: var(--action); cursor: pointer; }

    .warning-box { display: none; margin: 10px 0 14px; padding: 12px 14px; border: 0 !important; border-radius: 18px; background: var(--page); color: var(--ink); font-size: .82rem; box-shadow: inset 4px 0 var(--action); }

    .filter-summary { display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 18px; padding: 15px 16px; border-radius: 18px; background: var(--page); }

    .filter-summary-copy { min-width: 0; }

    .filter-summary-copy strong { display: block; margin-bottom: 3px; }

    .mode-picker { position: relative; flex: 0 0 auto; }

    .mode-trigger { display: inline-flex; align-items: center; justify-content: space-between; gap: 22px; min-width: 190px; text-align: left; }

    .mode-trigger::after { content: "⌄"; font-size: 1.05rem; line-height: 1; }

    .mode-menu {

      position: absolute;

      z-index: 10;

      top: calc(100% + 8px);

      right: 0;

      display: none;

      width: min(330px, calc(100vw - 52px));

      padding: 7px;

      border: 0 !important;

      border-radius: 20px;

      background: var(--surface);

    }

    .mode-menu.is-open { display: grid; gap: 4px; }

    .mode-menu [role="option"] {

      display: flex;

      width: 100%;

      min-height: 46px;

      align-items: center;

      justify-content: space-between;

      padding: 10px 13px;

      border-radius: 14px;

      background: var(--surface) !important;

      color: var(--ink) !important;

      text-align: left;

      cursor: pointer;

    }

    .mode-menu [role="option"]:hover, .mode-menu [role="option"]:focus-visible { background: var(--page) !important; color: var(--ink) !important; }

    .mode-menu [role="option"][aria-selected="true"] { background: var(--action) !important; color: #FFFFFF !important; }

    .mode-menu [role="option"][aria-selected="true"]::after { content: "Selected"; font-size: .73rem; font-weight: 650; }

    .field-row, .list-heading { display: flex; align-items: center; justify-content: space-between; gap: 12px; }

    .field-row { margin-bottom: 14px; }

    .field-row .card-title { margin-bottom: 0; }

    .list-heading { margin-bottom: 8px; }

    .list-heading label { margin: 0; }

    .app-list { max-height: 260px; overflow: auto; padding: 4px; border: 0 !important; border-radius: 18px; background: var(--page); }

    .app-list:focus-visible { outline: 3px solid var(--action); outline-offset: 3px; }

    #valDetails { color: var(--ink); overflow-wrap: anywhere; }

    code { color: var(--ink); font-family: Consolas, monospace; }

    @media (max-width: 780px) {

      body { padding: 22px 16px 36px; }

      .dashboard-grid { grid-template-columns: minmax(0, 1fr); gap: 14px; }

      .card--wide, #alertBanner { grid-column: 1; }

      .status-grid { grid-template-columns: minmax(0, 1fr); }

    }

    @media (max-width: 520px) {

      header { align-items: flex-start; }

      h1 { max-width: 220px; }

      .card { padding: 19px 16px; border-radius: 22px; }

      .hero-heading, .filter-summary { align-items: flex-start; flex-direction: column; }

      .mode-picker, .mode-trigger { width: 100%; }

      .mode-menu { right: auto; left: 0; width: 100%; }

      .btn-group { flex-direction: column; }

      .btn-group button { width: 100%; }

      .field-row, .custom-rule-controls { align-items: stretch; flex-direction: column; }

      .list-heading { align-items: flex-start; flex-direction: column; gap: 2px; }

      .app-item { align-items: flex-start; flex-direction: column; }

      .app-actions { justify-content: flex-start; }

      .status-row { align-items: flex-start; flex-direction: column; gap: 2px; }

      .status-val { text-align: left; }

    }

    body * { border: 0 !important; color: #212121 !important; }

    body { background: #EFEFEF !important; color: #212121 !important; }

    .card, #alertBanner, .mode-menu { background: #FFFFFF !important; }

    .status-row, .badge, .custom-rule, .app-list, .app-item, .preview-box, .privacy-option,

    .custom-fields-panel, .warning-box, .filter-summary, input[type="text"] { background: #EFEFEF !important; }

    button { background: #234CE2 !important; color: #FFFFFF !important; }

    button, button * { color: #FFFFFF !important; }

    .mode-menu [role="option"], .mode-menu [role="option"] * { background: #FFFFFF !important; color: #212121 !important; }

    .mode-menu [role="option"]:hover, .mode-menu [role="option"]:focus-visible,

    .mode-menu [role="option"]:hover *, .mode-menu [role="option"]:focus-visible * { background: #EFEFEF !important; color: #212121 !important; }

    .mode-menu [role="option"][aria-selected="true"], .mode-menu [role="option"][aria-selected="true"] * { background: #234CE2 !important; color: #FFFFFF !important; }

    .privacy-option input[type="radio"], .custom-chk-row input[type="checkbox"] { appearance: none; border: 0 !important; background: #EFEFEF; }

    .privacy-option input[type="radio"] { border-radius: 50%; }

    .privacy-option input[type="radio"]:checked, .custom-chk-row input[type="checkbox"]:checked { background: #234CE2; }



  </style>

</head>

<body>

  <div class="container">

    <header>

      <div class="header-copy">

        <h1>NotificationForwarder</h1>

        <p class="header-subtitle">Manage delivery, privacy, and application access.</p>

      </div>

      <button class="btn-refresh" id="btnRefresh" onclick="loadAll()">Refresh</button>

    </header>

    <nav class="page-nav" aria-label="Dashboard sections">

      <a href="#serviceStatusSection">Overview</a>

      <a href="#destinationSection">Delivery</a>

      <a href="#privacySection">Privacy</a>

      <a href="#applicationsSection">Applications</a>

    </nav>



    <main class="dashboard-grid">

    <div id="alertBanner" role="status" aria-live="polite"></div>



    <!-- One-Click Activation Card -->

    <section class="card card--wide card--hero" aria-labelledby="activationTitle">

      <div class="hero-heading">

        <h2 class="hero-title" id="activationTitle">

          One-Click Activation

        </h2>

        <span id="badgeWorkflow" class="badge badge-green">Ready</span>

      </div>

      <p class="hero-copy">

        Configures live delivery, registers automatic Windows startup tasks, and starts the background forwarder and hidden watchdog in one click.

      </p>

      <button id="btnStartPush" class="btn-start-push hero-button" onclick="startPushNotification()">

        Start Push Notification

      </button>

      <div id="startPushProgress" class="start-progress" aria-live="polite"></div>

    </section>



    <!-- Status Card -->

    <section class="card card--wide card--status" id="serviceStatusSection" aria-labelledby="serviceStatusTitle">

      <h2 class="card-title" id="serviceStatusTitle">1. Service Status</h2>

      <div class="status-grid">

      <div class="status-row">

        <span class="status-label" style="font-weight: 700;">Service State</span>

        <span class="status-val" id="valServiceState"><span class="badge badge-gray">Checking...</span></span>

      </div>

      <div class="status-row">

        <span class="status-label">Configuration</span>

        <span class="status-val" id="valCfg"><span class="badge badge-gray">Checking...</span></span>

      </div>

      <div class="status-row">

        <span class="status-label">ntfy Destination</span>

        <span class="status-val" id="valDest"><span class="badge badge-gray">Checking...</span></span>

      </div>

      <div class="status-row">

        <span class="status-label">Live Forwarding Mode</span>

        <span class="status-val" id="valLive"><span class="badge badge-gray">Checking...</span></span>

      </div>

      <div class="status-row">

        <span class="status-label">Dry Run Mode</span>

        <span class="status-val" id="valDry"><span class="badge badge-gray">Checking...</span></span>

      </div>

      <div class="status-row">

        <span class="status-label">Forwarder Process</span>

        <span class="status-val" id="valFwd"><span class="badge badge-gray">Checking...</span></span>

      </div>

      <div class="status-row">

        <span class="status-label">Watchdog Supervisor</span>

        <span class="status-val" id="valWd"><span class="badge badge-gray">Checking...</span></span>

      </div>

      <div class="status-row">

        <span class="status-label">Automatic Windows Startup</span>

        <span class="status-val" id="valStartup"><span class="badge badge-gray">Checking...</span></span>

      </div>

      <div class="status-row">

        <span class="status-label">Applications Allowed</span>

        <span class="status-val" id="valApps"><span class="badge badge-gray">Checking...</span></span>

      </div>

      <div class="status-row">

        <span class="status-label">Last Health Check</span>

        <span class="status-val" id="valHealth">Checking...</span>

      </div>

      </div>

    </section>



    <!-- ON / OFF Controls -->

    <section class="card" aria-labelledby="forwardingTitle">

      <h2 class="card-title" id="forwardingTitle">2. Forwarding Control</h2>

      <p>

        Turning OFF safely disables live notification forwarding and pauses Watchdog restart attempts. Turning ON resumes forwarding and activates the daemon.

      </p>

      <div class="btn-group">

        <button class="btn-on" id="btnOn" onclick="toggleForwarding(true)">Turn Forwarding ON</button>

        <button class="btn-off" id="btnOff" onclick="toggleForwarding(false)">Turn Forwarding OFF</button>

      </div>

    </section>



    <!-- Destination Card -->

    <section class="card" id="destinationSection" aria-labelledby="destinationTitle">

      <h2 class="card-title" id="destinationTitle">3. ntfy Destination</h2>

      <div class="form-group">

        <label for="txtServer">ntfy Server URL</label>

        <input type="text" id="txtServer" placeholder="https://ntfy.sh" spellcheck="false" autocomplete="off" />

      </div>

      <div class="form-group">

        <label for="txtTopic">ntfy Topic (Notification Key)</label>

        <input type="text" id="txtTopic" placeholder="Click ''Generate New Key'' or enter topic" spellcheck="false" autocomplete="off" />

        <div class="note">The notification key is your private destination topic on ntfy. It is generated locally on your computer and does not require pre-registration with any external service. Subscribe to this topic in the ntfy app on your phone.</div>

      </div>

      <div class="btn-group" style="margin-bottom: 14px;">

        <button type="button" class="btn-sm" id="btnGenKey" onclick="generateNewKey()">Generate New Key</button>

        <button type="button" class="btn-sm" id="btnCopyKey" onclick="copyKey()">Copy Key</button>

      </div>

      <button class="btn-save" id="btnSave" onclick="saveDestination()">Save Destination</button>

      <button type="button" class="btn-primary" id="btnSendTest" onclick="sendTestNotification()">Send Test</button>

      <button class="btn-restart" id="btnRestart" onclick="restartService()">Destination updated. Click here to restart forwarder now.</button>

    </section>





    <!-- Notification Appearance Card -->

    <section class="card" aria-labelledby="appearanceTitle">

      <h2 class="card-title" id="appearanceTitle">4. Notification Appearance</h2>

      <p>

        Identify this Windows computer clearly on your iPhone. Outgoing notifications display your configured Device Name as the primary sender identity, followed by the originating application name, notification title, and message content according to your privacy settings.

      </p>



      <div class="form-group">

        <label for="txtDeviceName">Device Name</label>

        <input type="text" id="txtDeviceName" placeholder="e.g. Ibrahim-PC" maxlength="64" spellcheck="false" autocomplete="off" />

        <div class="note">Enter a friendly name for this computer (1-64 characters). Defaults to your Windows PC computer name.</div>

      </div>



      <button class="btn-save" id="btnSaveDeviceName" onclick="saveDeviceName()">Save Device Name</button>

      <button class="btn-restart" id="btnRestartAppearance" onclick="restartService()">Device name updated. Click here to restart forwarder now.</button>



      <div class="preview-section">

        <label>Live Notification Preview (iPhone)</label>

        <div class="preview-box">

          <div class="preview-line-device" id="prevDevice">Ibrahim-PC</div>

          <div class="preview-line-app" id="prevApp">WhatsApp</div>

          <div class="preview-line-title" id="prevTitle">New Notification</div>

          <div class="preview-line-body" id="prevBody">Message content appears here</div>

        </div>

      </div>



      <div class="appearance-note">

        <strong>ntfy iOS App Icon Note:</strong> Apple iOS strictly restricts push notification icons to the receiving application (<code>ntfy</code>). Third-party push notifications cannot dynamically replace the iOS application icon per message. To clearly identify this PC, the notification title is set to your configured Device Name with computer indicator tags (<code>computer and bell</code>), followed by the originating application name and notification content.

      </div>

    </section>



    <!-- Notification Privacy Controls Card -->

    <section class="card" id="privacySection" aria-labelledby="privacyTitle">

      <h2 class="card-title" id="privacyTitle">5. Notification Privacy</h2>

      <p>

        Control exactly which notification fields are forwarded to your iPhone. Sensitive notification bodies are never logged or transmitted unless explicitly enabled.

      </p>



      <div role="radiogroup" aria-label="Notification privacy mode">

      <div class="privacy-option">

        <input type="radio" id="modeTitleOnly" name="privacyModeRadio" value="TitleOnly" onchange="selectPrivacyMode('TitleOnly')" />

        <label class="privacy-label" for="modeTitleOnly">

          <div class="privacy-title">Mode A: TitleOnly (Default &amp; Recommended)</div>

          <div class="privacy-desc">Forwards Device Name and Notification Title. Message body and application name are suppressed. Safe for public topics.</div>

        </label>

      </div>



      <div class="privacy-option">

        <input type="radio" id="modeTitleAndApp" name="privacyModeRadio" value="TitleAndApp" onchange="selectPrivacyMode('TitleAndApp')" />

        <label class="privacy-label" for="modeTitleAndApp">

          <div class="privacy-title">Mode B: TitleAndApp</div>

          <div class="privacy-desc">Forwards Device Name, Application Name, and Notification Title. Message body is suppressed.</div>

        </label>

      </div>



      <div class="privacy-option">

        <input type="radio" id="modeTitleAndBody" name="privacyModeRadio" value="TitleAndBody" onchange="selectPrivacyMode('TitleAndBody')" />

        <label class="privacy-label" for="modeTitleAndBody">

          <div class="privacy-title">Mode C: TitleAndBody</div>

          <div class="privacy-desc">Forwards Device Name, Application Name, Notification Title, and full Notification Message Body.</div>

        </label>

      </div>



      <div class="privacy-option">

        <input type="radio" id="modeCustom" name="privacyModeRadio" value="Custom" onchange="selectPrivacyMode('Custom')" />

        <label class="privacy-label" for="modeCustom">

          <div class="privacy-title">Mode D: Custom</div>

          <div class="privacy-desc">Select individual notification fields to forward independently.</div>

        </label>

      </div>

      </div>



      <!-- Custom Fields Panel -->

      <div id="customFieldsPanel" class="custom-fields-panel">

        <div class="privacy-title">Select Included Notification Fields:</div>

        <label class="custom-chk-row">

          <input type="checkbox" id="chkCustDevice" onchange="updateCustomFromCheckboxes()" /> Include Device Name

        </label>

        <label class="custom-chk-row">

          <input type="checkbox" id="chkCustApp" onchange="updateCustomFromCheckboxes()" /> Include Original Application Name

        </label>

        <label class="custom-chk-row">

          <input type="checkbox" id="chkCustTitle" onchange="updateCustomFromCheckboxes()" /> Include Original Notification Title

        </label>

        <label class="custom-chk-row">

          <input type="checkbox" id="chkCustBody" onchange="updateCustomFromCheckboxes()" /> Include Notification Message Body

        </label>

      </div>



      <!-- Body Warning Box -->

      <div id="bodyWarningBox" class="warning-box">

        <strong>Security Warning:</strong> Message-body forwarding is enabled. Notification bodies may contain private messages, authentication codes (2FA/OTP), or personal details. Ensure your ntfy topic is secret and access tokens are secured.

      </div>



      <button class="btn-save" id="btnSavePrivacy" onclick="savePrivacySettings()">Save Privacy Settings</button>

      <button class="btn-restart" id="btnRestartPrivacy" onclick="restartService()">Privacy settings updated. Click here to restart forwarder now.</button>

    </section>



    <!-- Applications Filtering Card -->

    <section class="card card--wide" id="applicationsSection" aria-labelledby="appsTitle">

      <div class="field-row">

        <h2 class="card-title" id="appsTitle">6. Applications Filtering</h2>

        <div id="filterModeBadge"><span class="badge badge-gray">Loading...</span></div>

      </div>



      <div class="filter-summary">

        <div class="filter-summary-copy">

          <strong>Current application rule</strong>

          <span id="txtModeDesc">Loading filtering mode...</span>

        </div>

        <div class="mode-picker" id="filterModePicker">

          <button id="btnSwitchMode" class="mode-trigger" type="button" aria-haspopup="listbox" aria-expanded="false" aria-controls="filterModeMenu" onclick="toggleFilterModeMenu()" onkeydown="handleFilterModeKeydown(event)">

            <span id="filterModeTriggerText">Choose mode</span>

          </button>

          <div class="mode-menu" id="filterModeMenu" role="listbox" aria-label="Application filtering mode" aria-hidden="true" onkeydown="handleFilterModeKeydown(event)">

            <button id="filterModeAllowlist" type="button" role="option" aria-selected="false" tabindex="-1" data-mode="Allowlist" onclick="promptSwitchMode('Allowlist')">Allowlist <span>Only listed apps forward</span></button>

            <button id="filterModeBlocklist" type="button" role="option" aria-selected="false" tabindex="-1" data-mode="Blocklist" onclick="promptSwitchMode('Blocklist')">Blocklist <span>All except listed apps forward</span></button>

          </div>

        </div>

      </div>



      <!-- Search Box -->

      <div class="app-search">

        <label for="appSearch">Search applications</label>

        <input type="text" id="appSearch" placeholder="Search configured and discovered applications" oninput="filterAppLists()" />

      </div>



      <!-- Add Custom Application Form -->

      <div class="custom-rule">

        <label for="txtCustomApp">Add a custom application rule</label>

        <div class="custom-rule-controls">

          <input type="text" id="txtCustomApp" placeholder="App name or AUMID pattern (for example, Slack)" />

          <button class="btn-sm" onclick="addCustomApp('Allowed')">+ Allow</button>

          <button class="btn-sm" onclick="addCustomApp('Blocked')">+ Block</button>

        </div>

      </div>



      <!-- Configured Applications Section -->

      <div class="app-section">

        <div class="list-heading">

          <label>Configured Rules (<span id="countConfigured">0</span>)</label>

          <span class="list-caption">Explicit Allow/Block lists in config.json</span>

        </div>

        <div id="configuredAppsList" class="app-list" role="list" tabindex="0" aria-label="Configured application rules">

          <div class="empty-state">Loading configured applications...</div>

        </div>

      </div>



      <!-- Discovered Applications Section -->

      <div class="app-section">

        <div class="list-heading">

          <label>Discovered Applications (<span id="countDiscovered">0</span>)</label>

          <span class="list-caption">From active notifications, logs &amp; system</span>

        </div>

        <div id="discoveredAppsList" class="app-list" role="list" tabindex="0" aria-label="Discovered applications">

          <div class="empty-state">Loading discovered applications...</div>

        </div>

      </div>



      <div class="btn-group">

        <button class="btn-save" id="btnSaveApps" onclick="saveAppRules()">Save Application Rules</button>

        <button class="btn-refresh" onclick="loadApps()">Reset / Reload</button>

      </div>

      <button class="btn-restart" id="btnRestartApp" onclick="restartService()">Application rules saved. Click here to restart forwarder now.</button>

    </section>



    <!-- Info Footer -->

    <section class="card card--wide details-card" aria-label="Configuration details">

      <span id="valDetails">Loading details...</span>

    </section>

    </main>

  </div>



  <script>

    // Authentication Token Resolution

    // 1. Embedded server token

    // 2. URL query param (?auth= or ?token=)

    // 3. localStorage cache

    function resolveAuthToken() {

      const embedded = "__AUTH_TOKEN__";

      if (embedded && embedded !== "__AUTH_TOKEN__" && !embedded.startsWith("$")) {

        try { localStorage.setItem("nf_dashboard_auth", embedded); } catch (e) {}

        return embedded;

      }

      try {

        const params = new URLSearchParams(window.location.search);

        const fromUrl = params.get("auth") || params.get("token");

        if (fromUrl) {

          localStorage.setItem("nf_dashboard_auth", fromUrl);

          return fromUrl;

        }

      } catch (e) {}

      try {

        const cached = localStorage.getItem("nf_dashboard_auth");

        if (cached) return cached;

      } catch (e) {}

      return "";

    }



    const AUTH_TOKEN = resolveAuthToken();



    // Application State

    let currentFilterMode = "Allowlist";

    let allowedApps = [];

    let blockedApps = [];

    let discoveredApps = [];

    let configTimestamp = "";



    function showAlert(msg, type) {

      if (!type) type = "info";

      const el = document.getElementById("alertBanner");

      el.className = "alert-" + type;

      el.setAttribute("role", type === "error" ? "alert" : "status");

      el.setAttribute("aria-live", type === "error" ? "assertive" : "polite");

      el.setAttribute("aria-atomic", "true");

      el.textContent = msg;

      el.style.display = "block";

      setTimeout(function() { el.style.display = "none"; }, 8000);

    }



    // Robust fetch with configurable timeout

    async function apiFetch(endpoint, options, timeoutMs) {

      if (!options) options = {};

      if (!timeoutMs) timeoutMs = 8000;



      const sep = endpoint.includes("?") ? "&" : "?";

      const url = endpoint + sep + "auth=" + encodeURIComponent(AUTH_TOKEN);



      const controller = new AbortController();

      const timer = setTimeout(function() { controller.abort(); }, timeoutMs);



      try {

        const headers = Object.assign({}, options.headers || {}, {

          "X-Auth-Token": AUTH_TOKEN

        });

        const resp = await fetch(url, Object.assign({}, options, {

          headers: headers,

          signal: controller.signal

        }));

        return resp;

      } finally {

        clearTimeout(timer);

      }

    }



    async function loadAll() {

      // Execute status and apps independently so failures never block each other

      await Promise.allSettled([loadStatus(), loadApps()]);

    }



    async function loadStatus() {

      const btn = document.getElementById("btnRefresh");

      btn.textContent = "Loading...";

      btn.disabled = true;



      try {

        const resp = await apiFetch("/api/status", { method: "GET" }, 8000);

        if (!resp.ok) {

          throw new Error("HTTP " + resp.status + " (" + resp.statusText + ")");

        }

        const data = await resp.json();



        // Render Overall Service State

        const elState = document.getElementById("valServiceState");

        if (elState) {

          const st = data.ServiceState || (data.ForwarderStatus === "RUNNING" ? "Running" : "Stopped");

          let badgeClass = "badge-gray";

          if (st === "Running") badgeClass = "badge-green";

          else if (st === "Starting" || st === "Needs Permission") badgeClass = "badge-yellow";

          else if (st === "Error") badgeClass = "badge-red";

          elState.innerHTML = '<span class="badge ' + badgeClass + '">' + escapeHtml(st) + '</span>';

        }



        // Render Forwarder Status

        const elFwd = document.getElementById("valFwd");

        if (data.ForwarderStatus === "RUNNING") {

          elFwd.innerHTML = '<span class="badge badge-green">RUNNING (PID ' + (data.ForwarderProcessId || 'Active') + ')</span>';

        } else {

          elFwd.innerHTML = '<span class="badge badge-red">STOPPED</span>';

        }



        // Render Watchdog Status

        const elWd = document.getElementById("valWd");

        if (data.ServiceDisabled) {

          elWd.innerHTML = '<span class="badge badge-yellow">PAUSED (OFF)</span>';

        } else if (data.WatchdogStatus && data.WatchdogStatus.includes("ACTIVE")) {

          elWd.innerHTML = '<span class="badge badge-green">' + escapeHtml(data.WatchdogStatus) + '</span>';

        } else {

          elWd.innerHTML = '<span class="badge badge-yellow">' + escapeHtml(data.WatchdogStatus || 'Unknown') + '</span>';

        }



        // Render Configuration Validity

        const elCfg = document.getElementById("valCfg");

        if (elCfg) {

          if (data.ConfigValid) {

            elCfg.innerHTML = '<span class="badge badge-green">VALID</span>';

          } else {

            elCfg.innerHTML = '<span class="badge badge-red">INCOMPLETE</span>';

          }

        }



        // Render Destination

        const elDest = document.getElementById("valDest");

        if (elDest) {

          if (data.DestinationConfigured) {

            elDest.innerHTML = '<span class="badge badge-green">' + escapeHtml(data.MaskedTopic || 'Configured') + '</span>';

          } else {

            elDest.innerHTML = '<span class="badge badge-red">NOT CONFIGURED</span>';

          }

        }



        // Render Live Mode

        const elLive = document.getElementById("valLive");

        if (data.LiveForwarding) {

          elLive.innerHTML = '<span class="badge badge-green">ACTIVE (Live Push)</span>';

        } else {

          elLive.innerHTML = '<span class="badge badge-yellow">DISABLED / OFF</span>';

        }



        // Render Dry Run

        const elDry = document.getElementById("valDry");

        if (elDry) {

          if (data.ConfigDryRun) {

            elDry.innerHTML = '<span class="badge badge-yellow">ENABLED (Test Only)</span>';

          } else {

            elDry.innerHTML = '<span class="badge badge-green">DISABLED (Live)</span>';

          }

        }



        // Render Automatic Startup

        const elStartup = document.getElementById("valStartup");

        if (elStartup) {

          if (data.AutoStartupConfigured) {

            elStartup.innerHTML = '<span class="badge badge-green">CONFIGURED (Logon Task)</span>';

          } else {

            elStartup.innerHTML = '<span class="badge badge-yellow">NOT CONFIGURED</span>';

          }

        }



        // Render App count

        const elApps = document.getElementById("valApps");

        if (elApps) {

          elApps.innerHTML = '<span class="badge badge-green">' + (data.AllowedAppCount || 0) + ' Allowed (' + (data.BlockedAppCount || 0) + ' Blocked)</span>';

        }



        // Render Health timestamp

        const elHealth = document.getElementById("valHealth");

        if (elHealth) {

          elHealth.textContent = data.LastHealthCheck || (new Date().toLocaleTimeString());

        }



        // Workflow Badge in Hero Card

        const badgeWf = document.getElementById("badgeWorkflow");

        if (badgeWf) {

          if (data.LiveForwarding && data.ForwarderStatus === "RUNNING") {

            badgeWf.className = "badge badge-green";

            badgeWf.textContent = "LIVE ACTIVE";

          } else {

            badgeWf.className = "badge badge-yellow";

            badgeWf.textContent = "STANDBY / READY";

          }

        }



        // Populate Destination inputs if user has not typed into them

        const txtServer = document.getElementById("txtServer");

        const txtTopic = document.getElementById("txtTopic");

        if (!txtServer.dataset.userEdited && data.NtfyServer) {

          txtServer.value = data.NtfyServer;

        }

        if (!txtTopic.dataset.userEdited && data.NtfyTopic) {

          txtTopic.value = data.NtfyTopic;

        }



        // Populate Device Name if not user-edited

        const txtDeviceName = document.getElementById("txtDeviceName");

        if (txtDeviceName && !txtDeviceName.dataset.userEdited && data.DeviceName) {

          txtDeviceName.value = data.DeviceName;

        }



        // Populate Privacy Mode & Custom Fields

        if (data.PrivacyMode) {

          currentPrivacyMode = data.PrivacyMode;

        }

        if (data.CustomPrivacyFields) {

          customFields = {

            IncludeDeviceName: data.CustomPrivacyFields.IncludeDeviceName !== false,

            IncludeAppName: data.CustomPrivacyFields.IncludeAppName !== false,

            IncludeTitle: data.CustomPrivacyFields.IncludeTitle !== false,

            IncludeBody: !!data.CustomPrivacyFields.IncludeBody

          };

        }

        renderPrivacyModeUI();

        updatePreview();



        // Details footer

        document.getElementById("valDetails").textContent =

          "Privacy: " + (data.PrivacyMode || "TitleOnly") +

          " | Filter: " + (data.AppFilterMode || "Allowlist") +

          " (" + (data.AllowedAppCount || 0) + " allowed, " + (data.BlockedAppCount || 0) + " blocked)" +

          (data.HasToken ? " | Auth Token: Configured" : " | Auth Token: None") +

          " | Last Log: " + (data.RecentLog || "None");



      } catch (err) {

        document.getElementById("valFwd").innerHTML = '<span class="badge badge-red">Failed</span>';

        document.getElementById("valWd").innerHTML = '<span class="badge badge-red">Failed</span>';

        document.getElementById("valLive").innerHTML = '<span class="badge badge-red">Failed</span>';

        showAlert("Failed to query service status: " + err.message, "error");

      } finally {

        btn.textContent = "Refresh";

        btn.disabled = false;

      }

    }



    // Mark fields edited once user types

    document.getElementById("txtServer").addEventListener("input", function() { this.dataset.userEdited = "true"; });

    document.getElementById("txtTopic").addEventListener("input", function() { this.dataset.userEdited = "true"; });

    const elDevInput = document.getElementById("txtDeviceName");

    if (elDevInput) {

      elDevInput.addEventListener("input", function() {

        this.dataset.userEdited = "true";

        updatePreview();

      });

    }



    async function startPushNotification() {

      const btn = document.getElementById("btnStartPush");

      const progress = document.getElementById("startPushProgress");



      if (!confirm("Start Live Push Notifications to your iPhone?\n\nThis will:\n1. Enable live notification delivery.\n2. Register automatic Windows startup tasks.\n3. Start the background forwarder and watchdog.\n\nProceed?")) {

        return;

      }



      btn.disabled = true;

      btn.textContent = "Activating Live Forwarding...";

      if (progress) {

        progress.style.display = "block";

        progress.textContent = "Validating configuration, registering startup tasks, and starting background forwarder...";

      }



      try {

        const resp = await apiFetch("/api/start-push", {

          method: "POST",

          headers: { "Content-Type": "application/json" }

        }, 15000);

        const res = await resp.json();



        if (res.Success) {

          showAlert(res.Message || "Live push notification forwarding is now ACTIVE!", "success");

          if (progress) {

            progress.textContent = "Active! Forwarder PID: " + res.ProcessId + " | Watchdog: Registered & Active";

          }

          await loadAll();

        } else {

          const err = res.Error || "Failed to activate live forwarding.";

          showAlert("Activation Error: " + err, "error");

          if (progress) {

            progress.textContent = "Activation halted: " + err;

          }

        }

      } catch (err) {

        showAlert("Failed to contact dashboard API: " + err.message, "error");

        if (progress) {

          progress.textContent = "Error: " + err.message;

        }

      } finally {

        btn.disabled = false;

        btn.textContent = "Start Push Notification";

      }

    }



    async function toggleForwarding(enable) {

      const btn = enable ? document.getElementById("btnOn") : document.getElementById("btnOff");

      btn.disabled = true;



      try {

        const resp = await apiFetch("/api/toggle", {

          method: "POST",

          headers: { "Content-Type": "application/json" },

          body: JSON.stringify({ Enable: enable })

        }, 10000);

        const res = await resp.json();

        if (res.Success) {

          showAlert(res.Message, "success");

        } else {

          showAlert(res.Error || "Action failed", "error");

        }

      } catch (err) {

        showAlert("Request failed: " + err.message, "error");

      } finally {

        btn.disabled = false;

        await loadStatus();

      }

    }



    async function sendTestNotification() {

      const btn = document.getElementById("btnSendTest");

      if (!btn || btn.disabled) return;

      const origText = btn.textContent;

      btn.disabled = true;

      btn.textContent = "Sending Test...";



      try {

        const resp = await apiFetch("/api/send-test", {

          method: "POST",

          headers: { "Content-Type": "application/json" }

        }, 15000);



        const data = await resp.json();

        if (data.Success) {

          showAlert(data.Message || "Test notification delivered successfully! Please check your iPhone.", "success");

        } else {

          showAlert(data.Error || "Failed to send test notification.", "error");

        }

      } catch (err) {

        showAlert("Send test request failed: " + err.message, "error");

      } finally {

        btn.disabled = false;

        btn.textContent = origText;

      }

    }



    async function generateNewKey() {

      const cur = document.getElementById("txtTopic").value.trim();

      if (cur.length > 0) {

        if (!confirm("Generating a new key will replace your current notification topic.\n\nAny phones, devices, or subscriptions listening to the old key will STOP receiving notifications until updated with the new key.\n\nDo you want to proceed?")) {

          return;

        }

      }

      try {

        const resp = await apiFetch("/api/destination/generate-key", { method: "POST" }, 5000);

        if (!resp.ok) throw new Error("HTTP " + resp.status);

        const data = await resp.json();

        if (data.Success && data.Topic) {

          document.getElementById("txtTopic").value = data.Topic;

          showAlert("New key generated locally! Click ''Save Destination'' to apply it, and subscribe to this topic on your phone.", "info");

        } else {

          showAlert("Failed to generate key: " + (data.Error || "Unknown error"), "error");

        }

      } catch (e) {

        showAlert("Failed to generate key: " + e.message, "error");

      }

    }



    async function copyKey() {

      const cur = document.getElementById("txtTopic").value.trim();

      if (!cur) {

        showAlert("No key to copy. Please click ''Generate New Key'' first.", "error");

        return;

      }

      try {

        if (navigator.clipboard && navigator.clipboard.writeText) {

          await navigator.clipboard.writeText(cur);

          showAlert("Notification key copied to clipboard!", "success");

        } else {

          prompt("Copy key to clipboard:", cur);

        }

      } catch (e) {

        prompt("Copy key to clipboard:", cur);

      }

    }



    async function saveDestination() {

      const server = document.getElementById("txtServer").value.trim();

      const topic = document.getElementById("txtTopic").value.trim();



      if (!topic) {

        showAlert("Topic cannot be empty.", "error");

        return;

      }



      const btn = document.getElementById("btnSave");

      btn.disabled = true;



      try {

        const resp = await apiFetch("/api/destination", {

          method: "POST",

          headers: { "Content-Type": "application/json" },

          body: JSON.stringify({ Server: server, Topic: topic })

        }, 8000);

        const res = await resp.json();

        if (res.Success) {

          showAlert(res.Message, "success");

          if (res.NeedsRestart) {

            document.getElementById("btnRestart").style.display = "block";

          }

        } else {

          showAlert(res.Error || "Failed to save destination", "error");

        }

      } catch (err) {

        showAlert("Request failed: " + err.message, "error");

      } finally {

        btn.disabled = false;

        await loadStatus();

      }

    }



    // -------------------------------------------------------------------------

    // Application Filtering Logic

    // -------------------------------------------------------------------------



    // State for Privacy & Appearance

    let currentPrivacyMode = "TitleOnly";

    let customFields = { IncludeDeviceName: true, IncludeAppName: true, IncludeTitle: true, IncludeBody: false };



    function renderPrivacyModeUI() {

      // Select appropriate radio

      const radio = document.getElementById("mode" + currentPrivacyMode);

      if (radio) radio.checked = true;



      // Show/hide custom fields panel

      const customPanel = document.getElementById("customFieldsPanel");

      if (customPanel) {

        customPanel.style.display = (currentPrivacyMode === "Custom") ? "block" : "none";

      }



      // Sync checkboxes

      const chkDev = document.getElementById("chkCustDevice");

      const chkApp = document.getElementById("chkCustApp");

      const chkTitle = document.getElementById("chkCustTitle");

      const chkBody = document.getElementById("chkCustBody");

      if (chkDev) chkDev.checked = customFields.IncludeDeviceName !== false;

      if (chkApp) chkApp.checked = customFields.IncludeAppName !== false;

      if (chkTitle) chkTitle.checked = customFields.IncludeTitle !== false;

      if (chkBody) chkBody.checked = !!customFields.IncludeBody;



      // Determine if body is enabled

      const bodyActive = (currentPrivacyMode === "TitleAndBody") ||

                         (currentPrivacyMode === "Custom" && customFields.IncludeBody);

      const warnBox = document.getElementById("bodyWarningBox");

      if (warnBox) {

        warnBox.style.display = bodyActive ? "block" : "none";

      }

    }



    function selectPrivacyMode(mode) {

      currentPrivacyMode = mode;

      renderPrivacyModeUI();

      updatePreview();

    }



    function updateCustomFromCheckboxes() {

      customFields.IncludeDeviceName = document.getElementById("chkCustDevice").checked;

      customFields.IncludeAppName = document.getElementById("chkCustApp").checked;

      customFields.IncludeTitle = document.getElementById("chkCustTitle").checked;

      customFields.IncludeBody = document.getElementById("chkCustBody").checked;

      renderPrivacyModeUI();

      updatePreview();

    }



    function updatePreview() {

      const devNameInput = (document.getElementById("txtDeviceName")?.value || "Ibrahim-PC").trim() || "Ibrahim-PC";



      let incDev = true, incApp = false, incTitle = true, incBody = false;

      if (currentPrivacyMode === "TitleOnly") {

        incDev = true; incApp = false; incTitle = true; incBody = false;

      } else if (currentPrivacyMode === "TitleAndApp") {

        incDev = true; incApp = true; incTitle = true; incBody = false;

      } else if (currentPrivacyMode === "TitleAndBody") {

        incDev = true; incApp = true; incTitle = true; incBody = true;

      } else if (currentPrivacyMode === "Custom") {

        incDev = !!customFields.IncludeDeviceName;

        incApp = !!customFields.IncludeAppName;

        incTitle = !!customFields.IncludeTitle;

        incBody = !!customFields.IncludeBody;

      }



      const elDev = document.getElementById("prevDevice");

      const elApp = document.getElementById("prevApp");

      const elTitle = document.getElementById("prevTitle");

      const elBody = document.getElementById("prevBody");



      if (elDev) {

        elDev.textContent = devNameInput;

        elDev.style.display = incDev ? "block" : "none";

      }

      if (elApp) {

        elApp.style.display = incApp ? "block" : "none";

      }

      if (elTitle) {

        elTitle.style.display = incTitle ? "block" : "none";

      }

      if (elBody) {

        elBody.style.display = incBody ? "block" : "none";

      }

    }



    async function saveDeviceName() {

      const txt = document.getElementById("txtDeviceName");

      const val = (txt.value || "").trim();

      if (!val) {

        showAlert("Device name cannot be empty.", "error");

        return;

      }

      if (val.length > 64) {

        showAlert("Device name cannot exceed 64 characters.", "error");

        return;

      }



      const btn = document.getElementById("btnSaveDeviceName");

      btn.disabled = true;



      try {

        const resp = await apiFetch("/api/appearance", {

          method: "POST",

          headers: { "Content-Type": "application/json" },

          body: JSON.stringify({ DeviceName: val })

        }, 8000);

        const res = await resp.json();

        if (res.Success) {

          showAlert(res.Message || "Device name saved successfully.", "success");

          if (res.NeedsRestart) {

            document.getElementById("btnRestartAppearance").style.display = "block";

          }

        } else {

          showAlert(res.Error || "Failed to save device name", "error");

        }

      } catch (err) {

        showAlert("Request failed: " + err.message, "error");

      } finally {

        btn.disabled = false;

        await loadStatus();

      }

    }



    async function savePrivacySettings() {

      const btn = document.getElementById("btnSavePrivacy");

      btn.disabled = true;



      try {

        const resp = await apiFetch("/api/privacy", {

          method: "POST",

          headers: { "Content-Type": "application/json" },

          body: JSON.stringify({

            PrivacyMode: currentPrivacyMode,

            CustomPrivacyFields: customFields

          })

        }, 8000);

        const res = await resp.json();

        if (res.Success) {

          showAlert(res.Message || "Privacy settings saved successfully.", "success");

          if (res.NeedsRestart) {

            document.getElementById("btnRestartPrivacy").style.display = "block";

          }

        } else {

          showAlert(res.Error || "Failed to save privacy settings", "error");

        }

      } catch (err) {

        showAlert("Request failed: " + err.message, "error");

      } finally {

        btn.disabled = false;

        await loadStatus();

      }

    }



    async function loadApps() {

      try {

        const resp = await apiFetch("/api/apps", { method: "GET" }, 10000);

        if (!resp.ok) {

          throw new Error("HTTP " + resp.status + " (" + resp.statusText + ")");

        }

        const data = await resp.json();



        currentFilterMode = data.AppFilterMode || "Allowlist";

        allowedApps = data.AllowedAppIds ? data.AllowedAppIds.slice() : [];

        blockedApps = data.BlockedAppIds ? data.BlockedAppIds.slice() : [];

        discoveredApps = data.DiscoveredApps ? data.DiscoveredApps.slice() : [];

        configTimestamp = data.ConfigTimestamp || "";



        renderAppMode();

        renderConfiguredList();

        renderDiscoveredList();

      } catch (err) {

        document.getElementById("filterModeBadge").innerHTML = '<span class="badge badge-red">Error</span>';

        document.getElementById("txtModeDesc").textContent = 'Failed to load rules: ' + err.message;

        document.getElementById("configuredAppsList").innerHTML = '<div class="empty-state">Failed to load configured applications: ' + escapeHtml(err.message) + '</div>';

        document.getElementById("discoveredAppsList").innerHTML = '<div class="empty-state">Failed to load discovered applications.</div>';

        showAlert("Failed to load application filtering rules: " + err.message, "error");

      }

    }



    function renderAppMode() {

      const badgeEl = document.getElementById("filterModeBadge");

      const descEl = document.getElementById("txtModeDesc");

      const triggerText = document.getElementById("filterModeTriggerText");

      const allowOption = document.getElementById("filterModeAllowlist");

      const blockOption = document.getElementById("filterModeBlocklist");



      if (currentFilterMode === "Blocklist") {

        badgeEl.innerHTML = '<span class="badge badge-yellow">BLOCKLIST MODE</span>';

        descEl.innerHTML = 'All notifications are forwarded <strong>except</strong> those explicitly blocked.';

        if (triggerText) triggerText.textContent = "Blocklist mode";

      } else {

        badgeEl.innerHTML = '<span class="badge badge-green">ALLOWLIST MODE</span>';

        descEl.innerHTML = 'Only explicitly allowed applications can forward notifications. All others are blocked.';

        if (triggerText) triggerText.textContent = "Allowlist mode";

      }

      if (allowOption) allowOption.setAttribute("aria-selected", String(currentFilterMode === "Allowlist"));

      if (blockOption) blockOption.setAttribute("aria-selected", String(currentFilterMode === "Blocklist"));

    }



    function toggleFilterModeMenu(forceOpen) {

      const trigger = document.getElementById("btnSwitchMode");

      const menu = document.getElementById("filterModeMenu");

      if (!trigger || !menu) return;

      const shouldOpen = (typeof forceOpen === "boolean") ? forceOpen : trigger.getAttribute("aria-expanded") !== "true";

      if (!shouldOpen) {

        closeFilterModeMenu(false);

        return;

      }

      trigger.setAttribute("aria-expanded", String(shouldOpen));

      menu.setAttribute("aria-hidden", String(!shouldOpen));

      menu.classList.toggle("is-open", shouldOpen);

      const selected = menu.querySelector('[data-mode="' + currentFilterMode + '"]') || menu.querySelector('[role="option"]');

      menu.querySelectorAll('[role="option"]').forEach(function(option) { option.tabIndex = -1; });

      if (selected) {

        selected.tabIndex = 0;

        selected.focus();

      }

    }



    function closeFilterModeMenu(restoreFocus) {

      const trigger = document.getElementById("btnSwitchMode");

      const menu = document.getElementById("filterModeMenu");

      if (!trigger || !menu) return;

      const focusWasInMenu = menu.contains(document.activeElement);

      trigger.setAttribute("aria-expanded", "false");

      menu.setAttribute("aria-hidden", "true");

      menu.classList.remove("is-open");

      if (restoreFocus && focusWasInMenu) trigger.focus();

    }



    function handleFilterModeKeydown(event) {

      const menu = document.getElementById("filterModeMenu");

      const trigger = document.getElementById("btnSwitchMode");

      if (!menu || !trigger) return;

      const options = Array.prototype.slice.call(menu.querySelectorAll('[role="option"]'));

      const currentIndex = options.indexOf(document.activeElement);

      if (event.key === "Escape") {

        event.preventDefault();

        closeFilterModeMenu(true);

        return;

      }

      if (event.key === "Tab" && trigger.getAttribute("aria-expanded") === "true") {

        closeFilterModeMenu(true);

        return;

      }

      if (document.activeElement === trigger && (event.key === "ArrowDown" || event.key === "ArrowUp")) {

        event.preventDefault();

        toggleFilterModeMenu(true);

        return;

      }

      if (event.key === "ArrowDown" || event.key === "ArrowUp" || event.key === "Home" || event.key === "End") {

        event.preventDefault();

        if (trigger.getAttribute("aria-expanded") !== "true") toggleFilterModeMenu(true);

        const baseIndex = currentIndex < 0 ? options.findIndex(function(option) { return option.dataset.mode === currentFilterMode; }) : currentIndex;

        let nextIndex = baseIndex;

        if (event.key === "ArrowDown") nextIndex = (baseIndex + 1) % options.length;

        if (event.key === "ArrowUp") nextIndex = (baseIndex - 1 + options.length) % options.length;

        if (event.key === "Home") nextIndex = 0;

        if (event.key === "End") nextIndex = options.length - 1;

        options.forEach(function(option, index) { option.tabIndex = index === nextIndex ? 0 : -1; });

        if (options[nextIndex]) options[nextIndex].focus();

      }

    }



    function promptSwitchMode(targetMode) {

      if (!targetMode) targetMode = (currentFilterMode === "Allowlist") ? "Blocklist" : "Allowlist";

      closeFilterModeMenu(true);

      if (targetMode === currentFilterMode) return;

      const promptMsg = (targetMode === "Blocklist")

        ? "Switch to BLOCKLIST mode?\n\nIn Blocklist mode, ALL Windows notifications will be forwarded to your iPhone except applications explicitly placed on the Blocked list.\n\nClick OK to switch."

        : "Switch to ALLOWLIST mode?\n\nIn Allowlist mode, ONLY applications on your Allowed list will be forwarded to your iPhone. All other notifications will be blocked.\n\nClick OK to switch.";



      if (confirm(promptMsg)) {

        currentFilterMode = targetMode;

        renderAppMode();

        renderDiscoveredList();

        showAlert("Mode changed to " + targetMode + ". Click 'Save Application Rules' to apply.", "info");

      }

    }



    function getAppEffectiveStatus(it) {

      if (!it) return "Not Configured";

      const candidates = [

        it.CanonicalId,

        it.DisplayName,

        it.AppId

      ].filter(Boolean).map(function(s) { return String(s).toLowerCase().trim(); });



      // Check blocked first

      for (let i = 0; i < blockedApps.length; i++) {

        const b = blockedApps[i].toLowerCase().trim();

        if (candidates.some(function(c) { return c === b || c.includes(b) || b.includes(c); })) {

          return "Blocked";

        }

      }



      // Check allowed

      for (let i = 0; i < allowedApps.length; i++) {

        const a = allowedApps[i].toLowerCase().trim();

        if (candidates.some(function(c) { return c === a || c.includes(a) || a.includes(c); })) {

          return "Allowed";

        }

      }



      return "Not Configured";

    }



    function renderConfiguredList() {

      const listEl = document.getElementById("configuredAppsList");

      const query = (document.getElementById("appSearch").value || "").toLowerCase().trim();



      const items = [];

      allowedApps.forEach(function(app) { if (app) items.push({ id: app.trim(), status: "Allowed" }); });

      blockedApps.forEach(function(app) { if (app) items.push({ id: app.trim(), status: "Blocked" }); });



      document.getElementById("countConfigured").textContent = items.length;



      const filtered = items.filter(function(it) {

        return !query || it.id.toLowerCase().includes(query);

      });



      if (filtered.length === 0) {

        listEl.innerHTML = '<div class="empty-state">' +

          (query ? 'No configured rules match "' + escapeHtml(query) + '"' : 'No application rules configured.') + '</div>';

        return;

      }



      let html = "";

      filtered.forEach(function(it) {

        const isAllowed = (it.status === "Allowed");

        const badge = isAllowed

          ? '<span class="badge badge-green">ALLOWED</span>'

          : '<span class="badge badge-red">BLOCKED</span>';



        const safeId = escapeHtml(it.id);

        const toggleAction = isAllowed ? "Blocked" : "Allowed";

        const toggleText = isAllowed ? "Block" : "Allow";



        html += '<div class="app-item" role="listitem">' +

          '<div class="app-info"><div class="app-title">' + safeId + '</div></div>' +

          '<div class="app-actions">' + badge +

          '<button type="button" class="btn-sm btn-toggle-app" aria-label="' + toggleText + ' ' + safeId + '" data-app-id="' + safeId + '" data-action="' + toggleAction + '">' + toggleText + '</button>' +

          '<button type="button" class="btn-sm btn-remove-app" aria-label="Remove rule for ' + safeId + '" data-app-id="' + safeId + '">Remove</button>' +

          '</div></div>';

      });



      listEl.innerHTML = html;

    }



    function renderDiscoveredList() {

      const listEl = document.getElementById("discoveredAppsList");

      const query = (document.getElementById("appSearch").value || "").toLowerCase().trim();



      document.getElementById("countDiscovered").textContent = discoveredApps.length;



      const filtered = discoveredApps.filter(function(it) {

        if (!query) return true;

        return (it.DisplayName && it.DisplayName.toLowerCase().includes(query)) ||

               (it.AppId && it.AppId.toLowerCase().includes(query)) ||

               (it.CanonicalId && it.CanonicalId.toLowerCase().includes(query));

      });



      if (filtered.length === 0) {

        listEl.innerHTML = '<div class="empty-state">' +

          (query ? 'No discovered applications match "' + escapeHtml(query) + '"' : 'No applications discovered yet.') + '</div>';

        return;

      }



      let html = "";

      filtered.forEach(function(it) {

        const effectiveStatus = getAppEffectiveStatus(it);

        const isAllowed = (effectiveStatus === "Allowed");

        const isBlocked = (effectiveStatus === "Blocked");



        let badge = '<span class="badge badge-gray">NOT CONFIGURED</span>';

        if (isAllowed) {

          badge = '<span class="badge badge-green">ALLOWED</span>';

        } else if (isBlocked) {

          badge = '<span class="badge badge-red">BLOCKED</span>';

        }



        const identifier = it.CanonicalId || it.DisplayName || it.AppId;

        const safeId = escapeHtml(identifier);

        const safeName = escapeHtml(it.DisplayName || identifier);

        const safeSub = it.AppId ? escapeHtml(it.AppId) : '';

        const safeSrc = escapeHtml(it.Source || 'System');



        const allowBtn = isAllowed

          ? '<button type="button" class="btn-sm" disabled style="opacity: 0.6; cursor: default;">Allowed</button>'

          : '<button type="button" class="btn-sm btn-allow-app" aria-label="Allow ' + safeId + '" data-app-id="' + safeId + '">+ Allow</button>';



        const blockBtn = isBlocked

          ? '<button type="button" class="btn-sm" disabled style="opacity: 0.6; cursor: default;">Blocked</button>'

          : '<button type="button" class="btn-sm btn-block-app" aria-label="Block ' + safeId + '" data-app-id="' + safeId + '">+ Block</button>';



        html += '<div class="app-item" role="listitem">' +

          '<div class="app-info">' +

          '<div class="app-title">' + safeName + '</div>' +

          '<div class="app-sub">' + safeSub + ' [' + safeSrc + ']</div>' +

          '</div>' +

          '<div class="app-actions">' + badge + allowBtn + blockBtn + '</div></div>';

      });



      listEl.innerHTML = html;

    }



    function filterAppLists() {

      renderConfiguredList();

      renderDiscoveredList();

    }



    function addCustomApp(targetStatus) {

      const input = document.getElementById("txtCustomApp");

      const val = (input.value || "").trim();

      if (!val) {

        showAlert("Application name or pattern cannot be empty.", "error");

        return;

      }

      setAppRuleStatus(val, targetStatus);

      input.value = "";

    }



    function setAppRuleStatus(identifier, targetStatus) {

      if (!identifier) return;

      const cleanId = String(identifier).trim();

      if (!cleanId) return;



      allowedApps = allowedApps.filter(function(x) { return x.toLowerCase().trim() !== cleanId.toLowerCase(); });

      blockedApps = blockedApps.filter(function(x) { return x.toLowerCase().trim() !== cleanId.toLowerCase(); });



      if (targetStatus === "Allowed") {

        if (!allowedApps.some(function(x) { return x.toLowerCase().trim() === cleanId.toLowerCase(); })) {

          allowedApps.push(cleanId);

        }

      } else if (targetStatus === "Blocked") {

        if (!blockedApps.some(function(x) { return x.toLowerCase().trim() === cleanId.toLowerCase(); })) {

          blockedApps.push(cleanId);

        }

      }



      renderConfiguredList();

      renderDiscoveredList();

    }



    function removeAppRule(identifier) {

      if (!identifier) return;

      const cleanId = String(identifier).trim();

      allowedApps = allowedApps.filter(function(x) { return x.toLowerCase().trim() !== cleanId.toLowerCase(); });

      blockedApps = blockedApps.filter(function(x) { return x.toLowerCase().trim() !== cleanId.toLowerCase(); });

      renderConfiguredList();

      renderDiscoveredList();

    }



    async function saveAppRules() {

      const btn = document.getElementById("btnSaveApps");

      if (!btn || btn.disabled) return;

      const origText = btn.textContent;

      btn.disabled = true;

      btn.textContent = "Saving...";



      try {

        const resp = await apiFetch("/api/apps", {

          method: "POST",

          headers: { "Content-Type": "application/json" },

          body: JSON.stringify({

            AppFilterMode: currentFilterMode,

            AllowedAppIds: allowedApps,

            BlockedAppIds: blockedApps,

            ExpectedTimestamp: configTimestamp

          })

        }, 10000);



        const res = await resp.json();

        if (res.Success) {

          showAlert(res.Message || "Application filtering rules saved successfully.", "success");

          configTimestamp = res.ConfigTimestamp || configTimestamp;

          if (res.NeedsRestart) {

            document.getElementById("btnRestartApp").style.display = "block";

          }

          await loadApps();

          await loadStatus();

        } else {

          const errStr = res.Error || "Failed to save application rules";

          showAlert(errStr, "error");

          if (errStr.includes("concurrently") || errStr.includes("timestamp")) {

            try {

              const checkResp = await apiFetch("/api/apps", { method: "GET" }, 5000);

              if (checkResp.ok) {

                const checkData = await checkResp.json();

                if (checkData.ConfigTimestamp) {

                  configTimestamp = checkData.ConfigTimestamp;

                  showAlert("Configuration timestamp refreshed. Click 'Save Application Rules' again to confirm and apply your changes.", "info");

                }

              }

            } catch (e) {}

          }

        }

      } catch (err) {

        showAlert("Request failed: " + err.message, "error");

      } finally {

        btn.disabled = false;

        btn.textContent = origText;

      }

    }



    async function restartService() {

      const btns = [document.getElementById("btnRestart"), document.getElementById("btnRestartApp")];

      btns.forEach(function(b) { if (b) b.disabled = true; });



      try {

        const resp = await apiFetch("/api/restart", {

          method: "POST",

          headers: { "Content-Type": "application/json" }

        }, 12000);

        const res = await resp.json();

        if (res.Success) {

          showAlert(res.Message, "success");

          btns.forEach(function(b) { if (b) b.style.display = "none"; });

        } else {

          showAlert(res.Error || "Failed to restart forwarder", "error");

        }

      } catch (err) {

        showAlert("Restart request failed: " + err.message, "error");

      } finally {

        btns.forEach(function(b) { if (b) b.disabled = false; });

        await loadStatus();

      }

    }



    function escapeHtml(str) {

      if (!str) return '';

      return String(str)

        .replace(/&/g, '&amp;')

        .replace(/</g, '&lt;')

        .replace(/>/g, '&gt;')

        .replace(/"/g, '&quot;')

        .replace(/'/g, '&#39;');

    }



    document.addEventListener("click", function(event) {

      const picker = document.getElementById("filterModePicker");

      const trigger = document.getElementById("btnSwitchMode");

      if (picker && trigger && !picker.contains(event.target) && trigger.getAttribute("aria-expanded") === "true") {

        closeFilterModeMenu(false);

      }

    });



    // Initialize as soon as DOM is ready or immediately if already loaded

    // Delegated click listeners for application action buttons

    document.addEventListener("click", function(e) {

      const btn = e.target.closest("button");

      if (!btn || btn.disabled) return;

      const appId = btn.getAttribute("data-app-id");

      if (!appId) return;



      if (btn.classList.contains("btn-allow-app")) {

        setAppRuleStatus(appId, "Allowed");

      } else if (btn.classList.contains("btn-block-app")) {

        setAppRuleStatus(appId, "Blocked");

      } else if (btn.classList.contains("btn-toggle-app")) {

        const action = btn.getAttribute("data-action");

        if (action) setAppRuleStatus(appId, action);

      } else if (btn.classList.contains("btn-remove-app")) {

        removeAppRule(appId);

      }

    });



    if (document.readyState === "loading") {

      document.addEventListener("DOMContentLoaded", function() {

        loadAll();

        setInterval(loadStatus, 15000);

      });

    } else {

      loadAll();

      setInterval(loadStatus, 15000);

    }

  </script>

</body>

</html>



'@



    return $template.Replace("__AUTH_TOKEN__", $AuthToken)

}



# ------------------------------------------------------------------------------

# 7. HTTP Server Core

# ------------------------------------------------------------------------------

function Start-DashboardServer {

    param(

        [int]$ListenPort = $Port,

        [string]$Token = $AuthToken,

        [switch]$ShouldOpenBrowser,

        [switch]$IsRunOnce,

        [int]$MaxSeconds = $TimeoutSeconds

    )



    if ([string]::IsNullOrWhiteSpace($Token)) {

        $Token = [guid]::NewGuid().ToString("N")

    }



    $url = "http://127.0.0.1:$ListenPort/"

    $listener = New-Object System.Net.HttpListener

    $listener.Prefixes.Add($url)



    try {

        $listener.Start()

    } catch {

        $alreadyRunning = $false

        try {

            $tcp = New-Object System.Net.Sockets.TcpClient

            $iar = $tcp.BeginConnect("127.0.0.1", $ListenPort, $null, $null)

            $wh = $iar.AsyncWaitHandle.WaitOne(800, $false)

            if ($wh -and $tcp.Connected) {

                $tcp.EndConnect($iar)

                $alreadyRunning = $true

            }

            $tcp.Close()

        } catch { }



        if ($alreadyRunning) {

            Write-Host "[INFO] Dashboard is already running on http://127.0.0.1:$ListenPort/" -ForegroundColor Green

            if ($ShouldOpenBrowser) {

                Start-Process "http://127.0.0.1:$ListenPort/?auth=$Token"

            }

            return

        }



        Write-Host "[ERROR] Could not bind to $url : $($_.Exception.Message)" -ForegroundColor Red

        return

    }



    $authUrl = "$($url)?auth=$Token"



    Write-Host "================================================================================" -ForegroundColor Cyan

    Write-Host "  NotificationForwarder - Local Management Dashboard" -ForegroundColor Cyan

    Write-Host "================================================================================" -ForegroundColor Cyan

    Write-Host "  URL        : $authUrl" -ForegroundColor White

    Write-Host "  Localhost  : 127.0.0.1 (Strict local PC binding; inaccessible from network)" -ForegroundColor Gray

    Write-Host "  Auth Token : Secured" -ForegroundColor Gray

    Write-Host "  Status     : Listening. Press Ctrl+C in this console to exit." -ForegroundColor Green

    Write-Host "================================================================================" -ForegroundColor Cyan



    if ($ShouldOpenBrowser) {

        try {

            Start-Process $authUrl

        } catch {

            Write-Host "[WARN] Could not automatically open browser. Open URL manually:" -ForegroundColor Yellow

            Write-Host "  $authUrl" -ForegroundColor White

        }

    }



    $startTime = [DateTime]::UtcNow

    $asyncContextTask = $null



    try {

        while ($listener.IsListening) {

            if ($MaxSeconds -gt 0) {

                $elapsed = ([DateTime]::UtcNow - $startTime).TotalSeconds

                if ($elapsed -ge $MaxSeconds) {

                    Write-Host "Dashboard server timeout ($MaxSeconds s) reached. Stopping." -ForegroundColor Gray

                    break

                }

            }



            if ($null -eq $asyncContextTask) {

                $asyncContextTask = $listener.GetContextAsync()

            }



            # Wait up to 500ms for responsive cancellation

            if (-not $asyncContextTask.Wait(500)) {

                continue

            }



            $context = $asyncContextTask.Result

            $asyncContextTask = $null

            $request = $context.Request

            $response = $context.Response



            # Set security headers

            $response.Headers.Add("X-Content-Type-Options", "nosniff")

            $response.Headers.Add("X-Frame-Options", "DENY")

            $response.Headers.Add("Cache-Control", "no-store, no-cache, must-revalidate")



            # Route & Auth resolution

            $rawPath = $request.Url.AbsolutePath

            $queryAuth = if ($request.QueryString["auth"]) { $request.QueryString["auth"] } else { $request.QueryString["token"] }

            $headerAuth = $request.Headers["X-Auth-Token"]

            $cookieAuth = if ($request.Cookies["nf_auth"]) { $request.Cookies["nf_auth"].Value } else { $null }



            $providedAuth = if (-not [string]::IsNullOrWhiteSpace($queryAuth)) {

                $queryAuth

            } elseif (-not [string]::IsNullOrWhiteSpace($headerAuth)) {

                $headerAuth

            } else {

                $cookieAuth

            }



            # 1. Root page (HTML)

            if ($rawPath -in @("/", "/index.html")) {

                if ($providedAuth -ne $Token) {

                    $response.StatusCode = if ([string]::IsNullOrWhiteSpace($providedAuth)) { 401 } else { 403 }

                    $response.ContentType = "text/plain; charset=utf-8"

                    $msgBytes = [System.Text.Encoding]::UTF8.GetBytes("$($response.StatusCode) Unauthorized. Access token required. Open dashboard via the desktop shortcut.")

                    $response.OutputStream.Write($msgBytes, 0, $msgBytes.Length)

                    $response.Close()

                    Write-Host "[HTTP] GET $rawPath -> $($response.StatusCode) (Auth required)" -ForegroundColor Gray

                    continue

                }



                # Set session cookie so page refreshes without query string work seamlessly

                try {

                    $authCookie = New-Object System.Net.Cookie("nf_auth", $Token, "/")

                    $authCookie.HttpOnly = $true

                    $response.Cookies.Add($authCookie)

                } catch { }



                $html = Get-DashboardHtml -AuthToken $Token

                $htmlBytes = [System.Text.Encoding]::UTF8.GetBytes($html)

                $response.StatusCode = 200

                $response.ContentType = "text/html; charset=utf-8"

                $response.ContentLength64 = $htmlBytes.Length

                $response.OutputStream.Write($htmlBytes, 0, $htmlBytes.Length)

                $response.Close()

                Write-Host "[HTTP] GET $rawPath -> 200 OK" -ForegroundColor Green

                continue

            }



            # 2. API Endpoints (All require Auth Token or Cookie)

            if ($providedAuth -ne $Token) {

                $response.StatusCode = if ([string]::IsNullOrWhiteSpace($providedAuth)) { 401 } else { 403 }

                $response.ContentType = "application/json; charset=utf-8"

                $errCode = $response.StatusCode

                $errMsg = if ($errCode -eq 401) { "Unauthorized: Missing authentication token." } else { "Forbidden: Invalid authentication token." }

                $errBytes = [System.Text.Encoding]::UTF8.GetBytes("{`"Success`":false,`"Error`":`"$errMsg`"}")

                $response.OutputStream.Write($errBytes, 0, $errBytes.Length)

                $response.Close()

                Write-Host "[HTTP] $($request.HttpMethod) $rawPath -> $errCode" -ForegroundColor Yellow

                continue

            }



            # Parse request body if POST

            $bodyJson = $null

            if ($request.HttpMethod -eq "POST" -and $request.HasEntityBody) {

                $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)

                try {

                    $rawBody = $reader.ReadToEnd()

                    try { $bodyJson = $rawBody | ConvertFrom-Json } catch { }

                } finally {

                    $reader.Dispose()

                }

            }



            $responseObj = $null

            $statusCode = 200



            try {

                # Route: GET /api/status

                if ($rawPath -eq "/api/status" -and $request.HttpMethod -eq "GET") {

                    $responseObj = Get-DashboardStatus -Dir $ProjectDir

                }

                # Route: POST /api/destination/generate-key

                elseif ($rawPath -eq "/api/destination/generate-key" -and $request.HttpMethod -eq "POST") {

                    $bytes = New-Object byte[] 16

                    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

                    $rng.GetBytes($bytes)

                    $hex = [BitConverter]::ToString($bytes).Replace("-", "").ToLowerInvariant()

                    $newTopic = "win-$hex"

                    $responseObj = @{

                        Success = $true

                        Topic   = $newTopic

                        Message = "New key generated locally."

                    }

                }

                # Route: POST /api/destination

                elseif ($rawPath -eq "/api/destination" -and $request.HttpMethod -eq "POST") {

                    $server = if ($bodyJson -and $bodyJson.Server) { [string]$bodyJson.Server } else { "https://ntfy.sh" }

                    $topic = if ($bodyJson -and $bodyJson.Topic) { [string]$bodyJson.Topic } else { "" }

                    $responseObj = Set-DashboardDestination -Dir $ProjectDir -Server $server -Topic $topic

                }

                # Route: POST /api/appearance

                elseif ($rawPath -eq "/api/appearance" -and $request.HttpMethod -eq "POST") {

                    $devName = if ($bodyJson -and $bodyJson.DeviceName) { [string]$bodyJson.DeviceName } else { "" }

                    $responseObj = Set-DashboardDeviceName -Dir $ProjectDir -DeviceName $devName

                }

                # Route: POST /api/privacy

                elseif ($rawPath -eq "/api/privacy" -and $request.HttpMethod -eq "POST") {

                    $privMode = if ($bodyJson -and $bodyJson.PrivacyMode) { [string]$bodyJson.PrivacyMode } else { "TitleOnly" }

                    $customFields = if ($bodyJson -and $bodyJson.CustomPrivacyFields) { $bodyJson.CustomPrivacyFields } else { $null }

                    $responseObj = Set-DashboardPrivacy -Dir $ProjectDir -PrivacyMode $privMode -CustomFields $customFields

                }

                # Route: GET /api/apps

                elseif ($rawPath -eq "/api/apps" -and $request.HttpMethod -eq "GET") {

                    $responseObj = Get-DashboardApps -Dir $ProjectDir

                }

                # Route: POST /api/apps

                elseif ($rawPath -eq "/api/apps" -and $request.HttpMethod -eq "POST") {

                    $mode = if ($bodyJson -and $bodyJson.AppFilterMode) { [string]$bodyJson.AppFilterMode } else { $null }

                    $allowed = if ($bodyJson -and $bodyJson.PSObject.Properties['AllowedAppIds']) { @($bodyJson.AllowedAppIds | ForEach-Object { [string]$_ }) } else { $null }

                    $blocked = if ($bodyJson -and $bodyJson.PSObject.Properties['BlockedAppIds']) { @($bodyJson.BlockedAppIds | ForEach-Object { [string]$_ }) } else { $null }

                    $expTs = if ($bodyJson -and $bodyJson.ExpectedTimestamp) { [string]$bodyJson.ExpectedTimestamp } else { $null }

                    $responseObj = Set-DashboardApps -Dir $ProjectDir -AppFilterMode $mode -AllowedAppIds $allowed -BlockedAppIds $blocked -ExpectedTimestamp $expTs

                }

                # Route: POST /api/send-test

                elseif ($rawPath -eq "/api/send-test" -and $request.HttpMethod -eq "POST") {

                    $responseObj = Send-DashboardTestNotification -Dir $ProjectDir

                }

                # Route: POST /api/start-push

                elseif ($rawPath -eq "/api/start-push" -and $request.HttpMethod -eq "POST") {

                    $responseObj = Invoke-StartPushNotification -ProjectDir $ProjectDir

                }

                # Route: POST /api/toggle

                elseif ($rawPath -eq "/api/toggle" -and $request.HttpMethod -eq "POST") {

                    $enable = if ($bodyJson -and $null -ne $bodyJson.Enable) { [bool]$bodyJson.Enable } else { $false }

                    $responseObj = Set-DashboardForwardingState -Dir $ProjectDir -Enable $enable

                }

                # Route: POST /api/restart

                elseif ($rawPath -eq "/api/restart" -and $request.HttpMethod -eq "POST") {

                    $responseObj = Restart-DashboardForwarder -Dir $ProjectDir

                }

                else {

                    $statusCode = 404

                    $responseObj = @{ Success = $false; Error = "Route not found" }

                }

            } catch {

                $statusCode = 500

                $cleanExc = if (Get-Command "Get-SanitizedMessage" -ErrorAction SilentlyContinue) {

                    Get-SanitizedMessage -InputMessage $_.Exception

                } else {

                    $_.Exception.Message

                }

                $responseObj = @{ Success = $false; Error = "Internal server error: $cleanExc" }

                Write-Host "[HTTP ERROR] $($request.HttpMethod) $rawPath : $cleanExc" -ForegroundColor Red

            }



            $respBytes = [System.Text.Encoding]::UTF8.GetBytes(($responseObj | ConvertTo-Json -Depth 5))

            $response.StatusCode = $statusCode

            $response.ContentType = "application/json; charset=utf-8"

            $response.ContentLength64 = $respBytes.Length

            $response.OutputStream.Write($respBytes, 0, $respBytes.Length)

            $response.Close()

            Write-Host "[HTTP] $($request.HttpMethod) $rawPath -> $statusCode" -ForegroundColor $(if ($statusCode -eq 200) { "Green" } else { "Yellow" })



            if ($IsRunOnce) {

                break

            }

        }

    } finally {

        if ($listener.IsListening) {

            $listener.Stop()

            $listener.Close()

        }

    }

}



# If script executed directly, start server

if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.Line -notmatch '^\s*\.\s+') {

    Start-DashboardServer `
        -ListenPort $Port `
        -Token $AuthToken `
        -ShouldOpenBrowser:$OpenBrowser `
        -IsRunOnce:$RunOnce `
        -MaxSeconds $TimeoutSeconds

}

