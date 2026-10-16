<#
.SYNOPSIS
    Notification sender, retry manager, and delivery pipeline for NotificationForwarder.
.DESCRIPTION
    Provides reliable delivery with bounded in-memory retry queue, exponential backoff,
    duplicate prevention, and hardened diagnostic logging.
    Strictly guarantees that no notification titles, bodies, topic names, authorization
    tokens, or secret URLs are ever written to console or logs.
#>

function New-DeliveryManager {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int]$MaxCapacity = 1000,

        [Parameter(Mandatory = $false)]
        [int]$MaxRetryQueue = 100
    )

    return @{
        DeliveredIds   = @{}
        OrderQueue     = New-Object System.Collections.Queue
        PendingRetries = @{}
        MaxCapacity    = $MaxCapacity
        MaxRetryQueue  = $MaxRetryQueue
    }
}

function Get-SanitizedErrorMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception,

        [Parameter(Mandatory = $false)]
        [hashtable]$Config = $null
    )

    if (Get-Command "Get-SanitizedMessage" -ErrorAction SilentlyContinue) {
        return Get-SanitizedMessage -InputMessage $Exception -Config $Config
    }

    # Bulletproof fallback if Config.ps1 is not yet in scope
    $raw = $Exception.Message
    if ($Exception.InnerException -and -not [string]::IsNullOrWhiteSpace($Exception.InnerException.Message)) {
        $raw += " | " + $Exception.InnerException.Message
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

function Get-PendingRetryItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Manager,

        [Parameter(Mandatory = $true)]
        [uint32]$NotificationId
    )

    $id = [uint32]$NotificationId
    if ($Manager.PendingRetries.ContainsKey($id)) {
        return $Manager.PendingRetries[$id]
    }
    return $null
}

function Test-IsDelivered {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Manager,

        [Parameter(Mandatory = $true)]
        [uint32]$NotificationId
    )

    $id = [uint32]$NotificationId
    return $Manager.DeliveredIds.ContainsKey($id)
}

function Test-IsPendingRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Manager,

        [Parameter(Mandatory = $true)]
        [uint32]$NotificationId
    )

    $id = [uint32]$NotificationId
    return $Manager.PendingRetries.ContainsKey($id)
}

function Mark-AsDelivered {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Manager,

        [Parameter(Mandatory = $true)]
        [uint32]$NotificationId
    )

    $id = [uint32]$NotificationId

    # Remove from pending retry queue if it was queued
    if ($Manager.PendingRetries.ContainsKey($id)) {
        $Manager.PendingRetries.Remove($id)
    }

    if (-not $Manager.DeliveredIds.ContainsKey($id)) {
        $Manager.DeliveredIds[$id] = [DateTime]::UtcNow
        $Manager.OrderQueue.Enqueue($id)

        # Enforce bounded capacity via LRU purging
        while ($Manager.OrderQueue.Count -gt $Manager.MaxCapacity) {
            $oldId = $Manager.OrderQueue.Dequeue()
            if ($Manager.DeliveredIds.ContainsKey($oldId)) {
                $Manager.DeliveredIds.Remove($oldId)
            }
        }
    }
}

function Enqueue-ForRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Manager,

        [Parameter(Mandatory = $true)]
        $FilteredNotification,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $false)]
        [int]$InitialAttemptCount = 1
    )

    $id = [uint32]$FilteredNotification.Id

    # Enforce retry queue capacity limit
    if ($Manager.PendingRetries.Count -ge $Manager.MaxRetryQueue) {
        # Find oldest pending entry to discard
        $oldestKey = $null
        $oldestTime = [DateTime]::MaxValue
        foreach ($key in $Manager.PendingRetries.Keys) {
            if ($Manager.PendingRetries[$key].EnqueuedUtc -lt $oldestTime) {
                $oldestTime = $Manager.PendingRetries[$key].EnqueuedUtc
                $oldestKey = $key
            }
        }
        if ($oldestKey) {
            $Manager.PendingRetries.Remove($oldestKey)
            # The dropped item is explicitly reported as discarded and never marked delivered
            Write-Host "[WARN] Pending retry queue capacity ($($Manager.MaxRetryQueue)) reached. Discarding oldest pending notification ID=$oldestKey." -ForegroundColor Yellow
        }
    }

    $delaySec = [Math]::Max(1.0, $Config.RetryInitialDelaySeconds)
    $maxAttempts = [Math]::Max(1, $Config.MaxRetries)

    $Manager.PendingRetries[$id] = @{
        Notification = $FilteredNotification
        Attempts     = $InitialAttemptCount
        MaxAttempts  = $maxAttempts
        DelaySeconds = $delaySec
        NextAttempt  = [DateTime]::UtcNow.AddSeconds($delaySec)
        EnqueuedUtc  = [DateTime]::UtcNow
    }
}

function Send-SingleAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $FilteredNotification,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $false)]
        [int]$AttemptNumber = 1,

        [Parameter(Mandatory = $false)]
        [scriptblock]$CustomHttpHandler = $null
    )

    $server = $Config.NtfyServer.TrimEnd('/')
    $topicUrl = "$server/$($Config.NtfyTopic)"

    $appLabel = [string]$FilteredNotification.AppLabel
    $originalTitle = [string]$FilteredNotification.Title
    $originalBody = [string]$FilteredNotification.Body

    # Check if this is a system / operational alert (e.g. Watchdog or Service Failure Alert)
    $isSystemAlert = ($FilteredNotification.PSObject.Properties["IsAlert"] -and $FilteredNotification.IsAlert) -or ($appLabel -eq "NotificationForwarder")

    if ($isSystemAlert) {
        # System alerts preserve their own header and message payload
        $headerTitle = "$appLabel`: $originalTitle"
        $headerTitleClean = ($headerTitle -replace '[
]+', ' ').Trim()
        if ($headerTitleClean.Length -gt 150) {
            $headerTitleClean = $headerTitleClean.Substring(0, 147) + "..."
        }

        $bodyPayload = if (-not [string]::IsNullOrWhiteSpace($originalBody)) {
            $originalBody
        } else {
            $originalTitle
        }

        $headers = @{
            "Title"    = $headerTitleClean
            "Priority" = "4"
            "Tags"     = "warning"
        }
    } else {
        # Detect if DeviceName or new Privacy modes are active
        $hasNewAppearanceConfig = ($Config.ContainsKey("DeviceName") -and -not [string]::IsNullOrWhiteSpace($Config.DeviceName)) -or ($Config.ContainsKey("CustomPrivacyFields") -and $Config.CustomPrivacyFields -ne $null) -or ($Config.PrivacyMode -in @("TitleAndApp", "Custom"))

        if (-not $hasNewAppearanceConfig) {
        # Legacy formatting for backward compatibility with sprint test suites
        $headerTitle = "$appLabel`: $originalTitle"
        $headerTitleClean = ($headerTitle -replace '[\r\n]+', ' ').Trim()
        if ($headerTitleClean.Length -gt 150) {
            $headerTitleClean = $headerTitleClean.Substring(0, 147) + "..."
        }

        $bodyPayload = if (-not [string]::IsNullOrWhiteSpace($originalBody)) {
            $originalBody
        } else {
            $originalTitle
        }

        $headers = @{
            "Title"    = $headerTitleClean
            "Priority" = "3"
        }
    } else {
        # New Custom Appearance & Privacy Formatting
        $permitted = if (Get-Command "Get-PermittedPrivacyFields" -ErrorAction SilentlyContinue) {
            Get-PermittedPrivacyFields -Config $Config
        } else {
            @{
                Mode              = $Config.PrivacyMode
                IncludeDeviceName = $true
                IncludeAppName    = ($Config.PrivacyMode -in @("TitleAndApp", "TitleAndBody"))
                IncludeTitle      = $true
                IncludeBody       = ($Config.PrivacyMode -eq "TitleAndBody")
            }
        }

        $deviceName = if (-not [string]::IsNullOrWhiteSpace($Config.DeviceName)) {
            $Config.DeviceName.Trim()
        } elseif (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
            $env:COMPUTERNAME
        } else {
            "Windows-PC"
        }

        # Build Title Header (Device Name as sender label where supported)
        $headerTitle = if ($permitted.IncludeDeviceName) {
            $deviceName
        } elseif ($permitted.IncludeAppName -and -not [string]::IsNullOrWhiteSpace($appLabel)) {
            $appLabel
        } elseif ($permitted.IncludeTitle -and -not [string]::IsNullOrWhiteSpace($originalTitle)) {
            $originalTitle
        } else {
            "Windows Notification"
        }

        $headerTitleClean = ($headerTitle -replace '[\r\n]+', ' ').Trim()
        if ($headerTitleClean.Length -gt 150) {
            $headerTitleClean = $headerTitleClean.Substring(0, 147) + "..."
        }

        # Build Message Body payload line by line:
        # Line 1: Application (if enabled)
        # Line 2: Original Notification Title (if enabled)
        # Line 3+: Original Message Body (if enabled)
        $bodyLines = @()
        if ($permitted.IncludeAppName -and -not [string]::IsNullOrWhiteSpace($appLabel)) {
            if ($permitted.IncludeDeviceName) {
                $bodyLines += $appLabel
            }
        }
        if ($permitted.IncludeTitle -and -not [string]::IsNullOrWhiteSpace($originalTitle)) {
            if ($permitted.IncludeDeviceName -or $permitted.IncludeAppName) {
                $bodyLines += $originalTitle
            }
        }
        if ($permitted.IncludeBody -and -not [string]::IsNullOrWhiteSpace($originalBody)) {
            $bodyLines += $originalBody
        }

        $bodyPayload = if ($bodyLines.Count -gt 0) {
            $bodyLines -join "`n"
        } else {
            if ($permitted.IncludeTitle -and -not [string]::IsNullOrWhiteSpace($originalTitle)) {
                $originalTitle
            } else {
                "Notification from $deviceName"
            }
        }

        $headers = @{
            "Title"    = $headerTitleClean
            "Priority" = "3"
            "Tags"     = "computer,bell"
        }
    }
    }

    if (-not [string]::IsNullOrWhiteSpace($Config.NtfyToken)) {
        $headers["Authorization"] = "Bearer $($Config.NtfyToken)"
    }

    try {
        if ($CustomHttpHandler) {
            $null = & $CustomHttpHandler -Url $topicUrl -Headers $headers -Body $bodyPayload -Attempt $AttemptNumber
        } else {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($bodyPayload)
            $response = Invoke-RestMethod `
                -Uri $topicUrl `
                -Method Post `
                -Headers $headers `
                -Body $bytes `
                -ContentType "text/plain; charset=utf-8" `
                -TimeoutSec 10 `
                -ErrorAction Stop
        }

        return @{
            Success = $true
            Error   = $null
        }
    } catch {
        $sanitized = Get-SanitizedErrorMessage -Exception $_.Exception -Config $Config
        return @{
            Success = $false
            Error   = $sanitized
        }
    }
}

function Send-Notification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $FilteredNotification,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [hashtable]$DeliveryManager,

        [Parameter(Mandatory = $false)]
        [scriptblock]$CustomHttpHandler = $null
    )

    $id = [uint32]$FilteredNotification.Id
    $appLabel = [string]$FilteredNotification.AppLabel

    # 1. Deduplication check: already delivered
    if (Test-IsDelivered -Manager $DeliveryManager -NotificationId $id) {
        Write-Verbose "[DEDUP] Notification ID=${id} from '${appLabel}' has already been delivered. Skipping."
        return @{
            Success = $true
            Skipped = $true
            Reason  = "AlreadyDelivered"
        }
    }

    # 2. In-flight check: already queued for retry
    if (Test-IsPendingRetry -Manager $DeliveryManager -NotificationId $id) {
        Write-Verbose "[DEDUP] Notification ID=${id} from '${appLabel}' is already in retry queue. Skipping re-queue."
        return @{
            Success = $true
            Skipped = $true
            Reason  = "PendingRetry"
        }
    }

    # 3. Dry-Run Safety Gate
    $isDryRun = ($Config.DryRun -eq $true) -or ($Config.LiveForwardingEnabled -ne $true)

    if ($isDryRun) {
        Mark-AsDelivered -Manager $DeliveryManager -NotificationId $id

        # Sanitized log: metadata only, never content or secret topic
        Write-Host ("[DRY-RUN] Would forward notification ID={0} from App='{1}' (TitleLen={2}, BodyLen={3}, Privacy={4}, Filter={5}). Destination: [TOPIC REDACTED]" -f `
            $id, $appLabel, $FilteredNotification.Title.Length, $FilteredNotification.Body.Length, $FilteredNotification.PrivacyMode, $FilteredNotification.AppFilterMode) `
            -ForegroundColor Cyan

        return @{
            Success = $true
            DryRun  = $true
            Skipped = $false
            Status  = "Simulated"
        }
    }

    # 4. Live Forwarding Validation
    if ([string]::IsNullOrWhiteSpace($Config.NtfyTopic)) {
        Write-Host "[SENDER ERROR] Cannot forward notification ID=${id}: Destination topic is not configured." -ForegroundColor Red
        return @{
            Success = $false
            DryRun  = $false
            Skipped = $false
            Reason  = "MissingTopic"
        }
    }

    # 5. Immediate Attempt (Attempt 1)
    $attemptResult = Send-SingleAttempt `
        -FilteredNotification $FilteredNotification `
        -Config $Config `
        -AttemptNumber 1 `
        -CustomHttpHandler $CustomHttpHandler

    if ($attemptResult.Success) {
        Mark-AsDelivered -Manager $DeliveryManager -NotificationId $id
        Write-Host ("[INFO] Forwarded notification ID={0} from App='{1}' (Attempt 1)." -f $id, $appLabel) -ForegroundColor Green
        return @{
            Success = $true
            DryRun  = $false
            Skipped = $false
            Status  = "Delivered"
            Attempt = 1
        }
    } else {
        # Queue for bounded exponential retry (not marked as delivered!)
        Write-Host ("[WARN] Initial delivery failed for notification ID={0} from App='{1}': {2}. Queued for retry." -f `
            $id, $appLabel, $attemptResult.Error) -ForegroundColor Yellow

        Enqueue-ForRetry `
            -Manager $DeliveryManager `
            -FilteredNotification $FilteredNotification `
            -Config $Config `
            -InitialAttemptCount 1

        return @{
            Success = $false
            DryRun  = $false
            Skipped = $false
            Status  = "QueuedForRetry"
            Error   = $attemptResult.Error
        }
    }
}

function Process-PendingRetries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$DeliveryManager,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $false)]
        [scriptblock]$CustomHttpHandler = $null
    )

    $now = [DateTime]::UtcNow
    $readyKeys = @()

    foreach ($key in $DeliveryManager.PendingRetries.Keys) {
        $item = $DeliveryManager.PendingRetries[$key]
        if ($item.NextAttempt -le $now) {
            $readyKeys += $key
        }
    }

    $processedCount = 0

    foreach ($id in $readyKeys) {
        if (-not $DeliveryManager.PendingRetries.ContainsKey($id)) { continue }

        $item = $DeliveryManager.PendingRetries[$id]
        $nextAttemptNum = $item.Attempts + 1
        $appLabel = [string]$item.Notification.AppLabel

        $res = Send-SingleAttempt `
            -FilteredNotification $item.Notification `
            -Config $Config `
            -AttemptNumber $nextAttemptNum `
            -CustomHttpHandler $CustomHttpHandler

        if ($res.Success) {
            Mark-AsDelivered -Manager $DeliveryManager -NotificationId $id
            Write-Host ("[INFO] Forwarded notification ID={0} from App='{1}' on retry attempt {2}/{3}." -f `
                $id, $appLabel, $nextAttemptNum, $item.MaxAttempts) -ForegroundColor Green
            $processedCount++
        } else {
            $item.Attempts = $nextAttemptNum
            if ($item.Attempts -ge $item.MaxAttempts) {
                # Exhaustion: remove from queue; NEVER marked as delivered!
                $DeliveryManager.PendingRetries.Remove($id)
                Write-Host ("[ERROR] Delivery permanently failed for notification ID={0} from App='{1}' after {2} attempts ({3}). Discarded from retry queue." -f `
                    $id, $appLabel, $item.MaxAttempts, $res.Error) -ForegroundColor Red
            } else {
                # Exponential backoff
                $item.DelaySeconds = $item.DelaySeconds * 2.0
                $item.NextAttempt = [DateTime]::UtcNow.AddSeconds($item.DelaySeconds)
                Write-Host ("[WARN] Retry attempt {0}/{1} failed for notification ID={2} ({3}). Next retry in {4}s." -f `
                    $item.Attempts, $item.MaxAttempts, $id, $res.Error, $item.DelaySeconds) -ForegroundColor Yellow
            }
        }
    }

    return $processedCount
}