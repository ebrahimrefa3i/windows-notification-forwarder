<#
.SYNOPSIS
    Notification reader and delta detector for Windows-to-iPhone Notification Forwarder.
.DESCRIPTION
    Interfaces with Windows Runtime (WinRT) UserNotificationListener to enumerate active toast
    notifications, extract visual elements safely, and compute added/removed deltas.
    Distinguishes genuine empty snapshots from query timeouts and API faults.
    Ensures all exception messages and logs are sanitized using active configuration.
#>

Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction SilentlyContinue

function Get-ReaderFallbackSanitized {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $InputMessage,

        [Parameter(Mandatory = $false)]
        [hashtable]$Config = $null
    )

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

function Initialize-NotificationReader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$Config = $null
    )

    try {
        [Windows.UI.Notifications.Management.UserNotificationListener, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.UI.Notifications.NotificationKinds, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.UI.Notifications.KnownNotificationBindings, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.UI.Notifications.UserNotification, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null

        $listener = [Windows.UI.Notifications.Management.UserNotificationListener]::Current
        $accessStatus = $listener.GetAccessStatus()

        if ($accessStatus -ne [Windows.UI.Notifications.Management.UserNotificationListenerAccessStatus]::Allowed) {
            throw "UserNotificationListener access is not Allowed. Current status: $accessStatus. Please enable Notification access in Windows Settings > Privacy & security > Notifications."
        }

        # Cache AsTask method for IAsyncOperation<IReadOnlyList<UserNotification>>
        $m = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { 
            $_.Name -eq 'AsTask' -and 
            $_.IsGenericMethod -and 
            $_.GetParameters().Length -eq 1 -and 
            $_.GetGenericArguments().Length -eq 1 
        } | Select-Object -First 1

        if (-not $m) {
            throw "Could not locate WindowsRuntimeSystemExtensions.AsTask generic method."
        }

        $userNotifType = [Windows.UI.Notifications.UserNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $roListType = [System.Collections.Generic.IReadOnlyList``1].MakeGenericType(@($userNotifType))
        $asTaskConstructed = $m.MakeGenericMethod(@($roListType))

        $kindsType = [Windows.UI.Notifications.NotificationKinds, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $toastKind = [System.Enum]::Parse($kindsType, "Toast")

        return @{
            Listener     = $listener
            AsTaskMethod = $asTaskConstructed
            ToastKind    = $toastKind
            Config       = $Config
            Initialized  = $true
        }
    } catch {
        $cleanErr = if (Get-Command "Get-SanitizedMessage" -ErrorAction SilentlyContinue) {
            Get-SanitizedMessage -InputMessage $_.Exception -Config $Config
        } else {
            Get-ReaderFallbackSanitized -InputMessage $_.Exception -Config $Config
        }
        throw "Failed to initialize NotificationReader: $cleanErr"
    }
}

function Get-CurrentNotifications {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ReaderContext,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutMs = 4000,

        [Parameter(Mandatory = $false)]
        [hashtable]$Config = $null
    )

    $activeConfig = if ($Config) { $Config } elseif ($ReaderContext.Config) { $ReaderContext.Config } else { $null }

    # 1. Allow mock reader provider for testing without live WinRT hardware listener
    if ($ReaderContext.ContainsKey("MockQueryHandler") -and $ReaderContext.MockQueryHandler -is [scriptblock]) {
        try {
            return (& $ReaderContext.MockQueryHandler)
        } catch {
            $cleanMockExc = if (Get-Command "Get-SanitizedMessage" -ErrorAction SilentlyContinue) {
                Get-SanitizedMessage -InputMessage $_.Exception -Config $activeConfig
            } else {
                Get-ReaderFallbackSanitized -InputMessage $_.Exception -Config $activeConfig
            }
            return @{
                Success       = $false
                Notifications = @{}
                ErrorCategory = "MockError"
                ErrorMessage  = "Mock reader query failed: $cleanMockExc"
            }
        }
    }

    # 2. Live WinRT polling
    $dict = @{}
    try {
        $asyncOp = $ReaderContext.Listener.GetNotificationsAsync($ReaderContext.ToastKind)
        $task = $ReaderContext.AsTaskMethod.Invoke($null, @($asyncOp))
        $completed = $task.Wait($TimeoutMs)

        if (-not $completed) {
            return @{
                Success       = $false
                Notifications = @{}
                ErrorCategory = "Timeout"
                ErrorMessage  = "GetNotificationsAsync timed out after ${TimeoutMs}ms."
            }
        }

        if ($task.IsFaulted) {
            $cleanFault = if (Get-Command "Get-SanitizedMessage" -ErrorAction SilentlyContinue) {
                Get-SanitizedMessage -InputMessage $task.Exception -Config $activeConfig
            } else {
                Get-ReaderFallbackSanitized -InputMessage $task.Exception -Config $activeConfig
            }
            return @{
                Success       = $false
                Notifications = @{}
                ErrorCategory = "TaskFault"
                ErrorMessage  = "GetNotificationsAsync query faulted: $cleanFault"
            }
        }

        foreach ($notif in $task.Result) {
            if ($notif -and $notif.Id) {
                $dict[[uint32]$notif.Id] = $notif
            }
        }

        return @{
            Success       = $true
            Notifications = $dict
            ErrorCategory = $null
            ErrorMessage  = $null
        }
    } catch {
        $cleanExc = if (Get-Command "Get-SanitizedMessage" -ErrorAction SilentlyContinue) {
            Get-SanitizedMessage -InputMessage $_.Exception -Config $activeConfig
        } else {
            Get-ReaderFallbackSanitized -InputMessage $_.Exception -Config $activeConfig
        }
        return @{
            Success       = $false
            Notifications = @{}
            ErrorCategory = "Exception"
            ErrorMessage  = "GetNotificationsAsync exception: $cleanExc"
        }
    }
}

function Extract-NotificationData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $UserNotification,

        [Parameter(Mandatory = $false)]
        [string]$PrivacyMode = "TitleOnly"
    )

    # Safe normalization: support TitleOnly, TitleAndApp, TitleAndBody, and Custom
    $normalizedPrivacy = switch -Regex ($PrivacyMode) {
        "(?i)^TitleAndBody$" { "TitleAndBody" }
        "(?i)^TitleAndApp$"  { "TitleAndApp" }
        "(?i)^Custom$"        { "Custom" }
        default              { "TitleOnly" }
    }

    $id = [uint32]$UserNotification.Id
    $aumid = ""
    $displayName = ""

    if ($UserNotification.AppInfo) {
        $aumid = [string]$UserNotification.AppInfo.AppUserModelId
        if ($UserNotification.AppInfo.DisplayInfo) {
            $displayName = [string]$UserNotification.AppInfo.DisplayInfo.DisplayName
        }
    }

    $rawTitle = ""
    $rawBody = ""
    $hasBody = $false

    try {
        $binding = $UserNotification.Notification.Visual.GetBinding(
            [Windows.UI.Notifications.KnownNotificationBindings]::ToastGeneric
        )

        if ($binding) {
            $elements = @($binding.GetTextElements())
            if ($elements.Count -gt 0 -and $elements[0]) {
                $rawTitle = [string]$elements[0].Text
            }
            if ($elements.Count -gt 1 -and $elements[1]) {
                $bodyLines = @()
                for ($i = 1; $i -lt $elements.Count; $i++) {
                    if ($elements[$i] -and -not [string]::IsNullOrWhiteSpace($elements[$i].Text)) {
                        $bodyLines += [string]$elements[$i].Text
                    }
                }
                if ($bodyLines.Count -gt 0) {
                    $rawBody = ($bodyLines -join "`n")
                    $hasBody = $true
                }
            }
        }
    } catch {
        Write-Verbose "Could not parse visual binding for notification ID ${id}."
    }

    # Apply privacy mode boundary at extraction point
    $isBodyPermitted = ($normalizedPrivacy -eq "TitleAndBody")
    $effectiveBody = if ($isBodyPermitted) { $rawBody } else { "" }

    return [PSCustomObject]@{
        Id              = $id
        AppUserModelId  = $aumid
        AppDisplayName  = $displayName
        CreationTime    = $UserNotification.CreationTime
        Title           = $rawTitle
        Body            = $effectiveBody
        HasBody         = $hasBody
        TitleLength     = $rawTitle.Length
        BodyLength      = $effectiveBody.Length
        PrivacyModeUsed = $normalizedPrivacy
    }
}

function Get-NotificationDeltas {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$CurrentDict,

        [Parameter(Mandatory = $true)]
        [hashtable]$KnownIds
    )

    $added = @()
    foreach ($id in $CurrentDict.Keys) {
        if (-not $KnownIds.ContainsKey($id)) {
            $added += $id
        }
    }

    $removed = @()
    foreach ($id in $KnownIds.Keys) {
        if (-not $CurrentDict.ContainsKey($id)) {
            $removed += $id
        }
    }

    return @{
        Added   = $added
        Removed = $removed
    }
}
