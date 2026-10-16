<#
.SYNOPSIS
    Main orchestrator and polling loop for Windows-to-iPhone Notification Forwarder.
.DESCRIPTION
    Continuously monitors Windows Toast notifications via WinRT delta tracking,
    applies application allowlist and privacy rules, manages an in-memory retry queue,
    and delivers payloads to ntfy. Handles polling errors and network drops gracefully.
    Sanitizes all error outputs and defaults to DRY RUN mode for safety.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$Once,

    [Parameter(Mandatory = $false)]
    [int]$MaxCycles = 0,

    [Parameter(Mandatory = $false)]
    [double]$PollInterval = 0,

    [Parameter(Mandatory = $false)]
    [hashtable]$MockReaderContext = $null,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = $null
)

# Set TLS 1.2/1.3 security protocol
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls

# Resolve script root directory
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    $scriptDir = (Get-Location).Path
}

# Resolve active log path if provided
if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
    if (-not [System.IO.Path]::IsPathRooted($LogPath)) {
        $script:ActiveLogPath = Join-Path -Path $scriptDir -ChildPath $LogPath
    } else {
        $script:ActiveLogPath = $LogPath
    }
} else {
    $script:ActiveLogPath = $null
}

# Scoped logger wrapper: mirrors all sanitized console output to log file when LogPath is configured
function Write-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        $Object,

        [Parameter(Mandatory = $false)]
        [ConsoleColor]$ForegroundColor
    )

    $msg = [string]$Object
    if ($PSBoundParameters.ContainsKey("ForegroundColor")) {
        Microsoft.PowerShell.Utility\Write-Host $msg -ForegroundColor $ForegroundColor
    } else {
        Microsoft.PowerShell.Utility\Write-Host $msg
    }

    if (-not [string]::IsNullOrWhiteSpace($script:ActiveLogPath)) {
        try {
            $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ssZ")
            $line = "[$timestamp] $msg"
            [System.IO.File]::AppendAllText($script:ActiveLogPath, "$line`r`n", [System.Text.Encoding]::UTF8)
        } catch { }
    }
}

# Dot-source required modules
$modules = @("Config.ps1", "NotificationReader.ps1", "NotificationFilter.ps1", "NotificationSender.ps1")
foreach ($module in $modules) {
    $modulePath = Join-Path -Path $scriptDir -ChildPath $module
    if (-not (Test-Path -Path $modulePath)) {
        Write-Error "Required module '$modulePath' not found. Exiting."
        exit 1
    }
    . $modulePath
}

function Initialize-NotificationBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ReaderContext,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [hashtable]$DeliveryManager
    )

    Write-Host "[BASELINE] Establishing notification baseline. Scanning existing notifications..." -ForegroundColor Gray
    $initialPoll = Get-CurrentNotifications -ReaderContext $ReaderContext -Config $Config

    if (-not $initialPoll.Success) {
        $cleanPollErr = Get-SanitizedMessage -InputMessage $initialPoll.ErrorMessage -Config $Config
        Write-Host ("[FATAL] Could not establish notification baseline ({0}): {1}" -f $initialPoll.ErrorCategory, $cleanPollErr) -ForegroundColor Red
        return @{
            Success  = $false
            KnownIds = @{}
            Error    = $cleanPollErr
        }
    }

    $knownIds = @{}
    foreach ($id in $initialPoll.Notifications.Keys) {
        $knownIds[$id] = $true
        Mark-AsDelivered -Manager $DeliveryManager -NotificationId $id
    }

    Write-Host ("[BASELINE] Baseline established: {0} pre-existing notifications identified. Historical alerts will NOT be forwarded." -f $knownIds.Count) -ForegroundColor Green
    return @{
        Success  = $true
        KnownIds = $knownIds
        Error    = $null
    }
}

function Invoke-NotificationForwarderCycle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ReaderContext,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [hashtable]$DeliveryManager,

        [Parameter(Mandatory = $true)]
        [hashtable]$KnownIds,

        [Parameter(Mandatory = $false)]
        [scriptblock]$CustomHttpHandler = $null
    )

    # 1. Process pending retries
    if ($DeliveryManager.PendingRetries.Count -gt 0) {
        $null = Process-PendingRetries -DeliveryManager $DeliveryManager -Config $Config -CustomHttpHandler $CustomHttpHandler
    }

    # 2. Fetch current notifications
    $pollResult = Get-CurrentNotifications -ReaderContext $ReaderContext -Config $Config

    # 3. Handle polling errors: preserve known state and skip delta calculation on error
    if (-not $pollResult.Success) {
        $cleanPollErr = Get-SanitizedMessage -InputMessage $pollResult.ErrorMessage -Config $Config
        Write-Host ("[WARN] Polling failed ({0}): {1}. Preserving last valid state; skipping delta calculation for this cycle." -f `
            $pollResult.ErrorCategory, $cleanPollErr) -ForegroundColor Yellow
        return @{
            PollSuccess  = $false
            AddedCount   = 0
            RemovedCount = 0
            Error        = $cleanPollErr
        }
    }

    # 4. Compute deltas against current valid state
    $deltas = Get-NotificationDeltas -CurrentDict $pollResult.Notifications -KnownIds $KnownIds

    $addedProcessed = 0
    # Process newly added notifications
    if ($deltas.Added.Count -gt 0) {
        foreach ($id in $deltas.Added) {
            $KnownIds[$id] = $true

            $rawNotif = $pollResult.Notifications[$id]
            if (-not $rawNotif) { continue }

            $data = Extract-NotificationData -UserNotification $rawNotif -PrivacyMode $Config.PrivacyMode
            $filtered = Filter-Notification -NotificationData $data -Config $Config

            if ($filtered) {
                $null = Send-Notification `
                    -FilteredNotification $filtered `
                    -Config $Config `
                    -DeliveryManager $DeliveryManager `
                    -CustomHttpHandler $CustomHttpHandler
                $addedProcessed++
            }
        }
    }

    $removedProcessed = 0
    # Process removed/dismissed notifications (clean up memory)
    if ($deltas.Removed.Count -gt 0) {
        foreach ($id in $deltas.Removed) {
            if ($KnownIds.ContainsKey($id)) {
                $KnownIds.Remove($id)
                $removedProcessed++
            }
        }
    }

    return @{
        PollSuccess  = $true
        AddedCount   = $addedProcessed
        RemovedCount = $removedProcessed
        Error        = $null
    }
}

# ---------------------------------------------------------
# Execution Entry Point (only runs when executed as a script, not dot-sourced)
# ---------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    # 1. Load Configuration
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path -Path $scriptDir -ChildPath "config.json"
    }

    $config = Load-AppConfig -ConfigPath $ConfigPath

    # Support LogPath from config if not passed via command line
    if ([string]::IsNullOrWhiteSpace($script:ActiveLogPath) -and $config.ContainsKey("LogPath") -and -not [string]::IsNullOrWhiteSpace($config["LogPath"])) {
        $cfgLog = [string]$config["LogPath"]
        if (-not [System.IO.Path]::IsPathRooted($cfgLog)) {
            $script:ActiveLogPath = Join-Path -Path $scriptDir -ChildPath $cfgLog
        } else {
            $script:ActiveLogPath = $cfgLog
        }
    }

    # Command-line parameter overrides
    if ($DryRun.IsPresent) {
        $config.DryRun = $true
    }
    if ($PollInterval -gt 0) {
        $config.PollIntervalSeconds = [Math]::Max(0.5, $PollInterval)
    }

    $isDryRun = ($config.DryRun -eq $true) -or ($config.LiveForwardingEnabled -ne $true)

    # Banner and Operational State
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  Windows-to-iPhone Notification Forwarder (PowerShell 5.1)" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ("  Mode:                 {0}" -f $(if ($isDryRun) { "DRY-RUN (Safe Simulation)" } else { "LIVE FORWARDING (Active)" })) -ForegroundColor $(if ($isDryRun) { "Yellow" } else { "Green" })
    Write-Host ("  Privacy Mode:         {0}" -f $config.PrivacyMode) -ForegroundColor White
    Write-Host ("  App Filter Mode:      {0}" -f $config.AppFilterMode) -ForegroundColor White
    Write-Host ("  Poll Interval:        {0}s" -f $config.PollIntervalSeconds) -ForegroundColor White
    Write-Host ("  Allowed Applications: {0} patterns loaded" -f $config.AllowedAppIds.Count) -ForegroundColor White
    Write-Host ("  Ignored Applications: {0} patterns loaded" -f $config.IgnoreAppIds.Count) -ForegroundColor White
    if ($script:ActiveLogPath) {
        Write-Host ("  Log File:             {0}" -f $script:ActiveLogPath) -ForegroundColor Gray
    }
    Write-Host "==========================================================" -ForegroundColor Cyan

    $configCheck = Test-AppConfig -Config $config
    if (-not $configCheck.IsValid) {
        foreach ($err in $configCheck.Errors) {
            $cleanErr = Get-SanitizedMessage -InputMessage $err -Config $config
            Write-Host "[CONFIG ERROR] $cleanErr" -ForegroundColor Red
        }
        if (-not $isDryRun) {
            Write-Host "[SAFETY GATE] Live forwarding requested but configuration is invalid. Reverting to DRY RUN." -ForegroundColor Yellow
            $config.DryRun = $true
            $isDryRun = $true
        }
    }

    # 1b. Check if intentionally disabled via marker file
    $disabledMarker = Join-Path -Path $scriptDir -ChildPath ".disabled"
    if (Test-Path $disabledMarker) {
        Write-Host "[DISABLED] NotificationForwarder is intentionally disabled (.disabled marker present). Exiting cleanly." -ForegroundColor Yellow
        exit 0
    }

    # 2. Initialize Notification Reader (or use Mock if provided)
    $reader = $null
    if ($MockReaderContext) {
        $reader = $MockReaderContext
        Write-Host "[INIT] Using injected MockReaderContext." -ForegroundColor Gray
    } else {
        Write-Host "[INIT] Initializing Windows Notification Listener..." -ForegroundColor Gray
        try {
            $reader = Initialize-NotificationReader -Config $config
            Write-Host "[INIT] Notification Listener initialized successfully (Access: Allowed)." -ForegroundColor Green
        } catch {
            $cleanInitErr = Get-SanitizedMessage -InputMessage $_.Exception -Config $config
            Write-Host "[FATAL] $cleanInitErr" -ForegroundColor Red
            exit 1
        }
    }

    # 3. Initialize Delivery & Retry Manager
    $deliveryManager = New-DeliveryManager `
        -MaxCapacity $config.MaxBacklogIds `
        -MaxRetryQueue $config.MaxPendingRetryQueue

    # 4. Establish Baseline (Historical notifications are ignored)
    $baselineResult = Initialize-NotificationBaseline `
        -ReaderContext $reader `
        -Config $config `
        -DeliveryManager $deliveryManager

    if (-not $baselineResult.Success) {
        exit 1
    }

    $knownIds = $baselineResult.KnownIds
    Write-Host "[RUNNING] Listening for new notifications... Press Ctrl+C to stop." -ForegroundColor Cyan

    # 5. Polling Loop Setup
    $script:Running = $true

    try {
        [Console]::TreatControlCAsInput = $false
    } catch {
        # Best-effort console configuration
    }

    $cycle = 0
    $lastConfigWriteTime = if (Test-Path $ConfigPath) { (Get-Item $ConfigPath).LastWriteTimeUtc } else { [DateTime]::MinValue }

    try {
        while ($script:Running) {
            $cycle++

            # Dynamic config reload if config.json was modified
            if (Test-Path $ConfigPath) {
                try {
                    $curWriteTime = (Get-Item $ConfigPath).LastWriteTimeUtc
                    if ($curWriteTime -ne $lastConfigWriteTime) {
                        $reloadedConfig = Load-AppConfig -ConfigPath $ConfigPath
                        $chk = Test-AppConfig -Config $reloadedConfig
                        if ($chk.IsValid) {
                            $config = $reloadedConfig
                            $lastConfigWriteTime = $curWriteTime
                            Write-Host ("[CONFIG] Dynamic configuration update reloaded (Mode={0}, Allowed={1}, Blocked={2})." -f `
                                $config.AppFilterMode, $config.AllowedAppIds.Count, $config.BlockedAppIds.Count) -ForegroundColor Gray
                        }
                    }
                } catch { }
            }

            # Execute single orchestrator cycle
            $cycleResult = Invoke-NotificationForwarderCycle `
                -ReaderContext $reader `
                -Config $config `
                -DeliveryManager $deliveryManager `
                -KnownIds $knownIds

            if ($Once.IsPresent) {
                Write-Host "[ONCE] Single cycle completed. Stopping." -ForegroundColor Gray
                break
            }

            if ($MaxCycles -gt 0 -and $cycle -ge $MaxCycles) {
                Write-Host "[CYCLE] Completed $cycle of $MaxCycles cycles. Stopping." -ForegroundColor Gray
                break
            }

            Start-Sleep -Seconds $config.PollIntervalSeconds
        }
    } finally {
        Write-Host "`n[SHUTDOWN] NotificationForwarder stopped cleanly. Cleanup complete." -ForegroundColor Yellow
    }
}
