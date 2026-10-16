<#

.SYNOPSIS

    NotificationForwarder Supervisor & Watchdog with Failure Alerting.

.DESCRIPTION

    Monitors the NotificationForwarder background daemon.

    If the daemon has stopped unexpectedly and is NOT intentionally disabled,

    it triggers an automatic restart and logs the recovery event to forwarder.log.

    If automatic recovery genuinely fails, it dispatches a single failure alert

    to the configured ntfy topic without exposing secrets or entering an alert loop.

    Clears the alert state automatically once the forwarder recovers.

    Guarantees no duplicate forwarder processes are ever started.

#>



[CmdletBinding()]

param(

    [Parameter(Mandatory = $false)]

    [string]$LogPath = $null,



    [Parameter(Mandatory = $false)]

    [string]$ForwarderTaskName = "NotificationForwarder",



    [Parameter(Mandatory = $false)]

    [string]$ConfigPath = $null,



    [Parameter(Mandatory = $false)]

    [string]$AlertStatePath = $null,



    [Parameter(Mandatory = $false)]

    [string]$NetworkStatePath = $null,



    [Parameter(Mandatory = $false)]

    [int]$NetworkOutageThreshold = 2,



    [Parameter(Mandatory = $false)]

    [scriptblock]$CustomNetworkChecker = $null,



    [Parameter(Mandatory = $false)]

    [switch]$DisableNetworkRecoveryAlert,



    [Parameter(Mandatory = $false)]

    [int]$RecoveryVerifySeconds = 2,



    [Parameter(Mandatory = $false)]

    [scriptblock]$CustomHttpHandler = $null,



    [Parameter(Mandatory = $false)]

    [switch]$DisableAlert,



    [Parameter(Mandatory = $false)]

    [switch]$ForceRestart,



    [Parameter(Mandatory = $false)]

    [switch]$PassThru

)



$ErrorActionPreference = "Stop"



$scriptDir = $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($scriptDir)) {

    $scriptDir = (Get-Location).Path

}



# Resolve active log path

if ([string]::IsNullOrWhiteSpace($LogPath)) {

    $LogPath = Join-Path -Path $scriptDir -ChildPath "forwarder.log"

} elseif (-not [System.IO.Path]::IsPathRooted($LogPath)) {

    $LogPath = Join-Path -Path $scriptDir -ChildPath $LogPath

}



$disabledMarker = Join-Path -Path $scriptDir -ChildPath ".disabled"



# Resolve alert state marker file (persisted per failure incident)

if ([string]::IsNullOrWhiteSpace($AlertStatePath)) {

    $alertStateFile = Join-Path -Path $scriptDir -ChildPath ".alert_state"

} elseif (-not [System.IO.Path]::IsPathRooted($AlertStatePath)) {

    $alertStateFile = Join-Path -Path $scriptDir -ChildPath $AlertStatePath

} else {

    $alertStateFile = $AlertStatePath

}



# Resolve network recovery state marker file (persisted per network outage)

if ([string]::IsNullOrWhiteSpace($NetworkStatePath)) {

    $networkStateFile = Join-Path -Path $scriptDir -ChildPath ".network_state"

} elseif (-not [System.IO.Path]::IsPathRooted($NetworkStatePath)) {

    $networkStateFile = Join-Path -Path $scriptDir -ChildPath $NetworkStatePath

} else {

    $networkStateFile = $NetworkStatePath

}



# Resolve config path

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {

    $configFile = Join-Path -Path $scriptDir -ChildPath "config.json"

} elseif (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {

    $configFile = Join-Path -Path $scriptDir -ChildPath $ConfigPath

} else {

    $configFile = $ConfigPath

}



# Load helper dependencies if available

$configScript = Join-Path -Path $scriptDir -ChildPath "Config.ps1"

$senderScript = Join-Path -Path $scriptDir -ChildPath "NotificationSender.ps1"



if (Test-Path $configScript) {

    try { . $configScript } catch { }

}

if (Test-Path $senderScript) {

    try { . $senderScript } catch { }

}



# Safe log writer to forwarder.log

function Write-WatchdogLog {

    param([string]$Message)

    try {

        $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ssZ")

        $logLine = "[$timestamp] [WATCHDOG] $Message"

        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {

            [System.IO.File]::AppendAllText($LogPath, "$logLine`r`n", [System.Text.Encoding]::UTF8)

        }

        Write-Verbose $logLine

    } catch { }

}



# Safe app config loader

function Get-WatchdogConfig {

    if (Get-Command "Load-AppConfig" -ErrorAction SilentlyContinue) {

        try {

            return Load-AppConfig -ConfigPath $configFile

        } catch { }

    }



    if (Test-Path $configFile) {

        try {

            $raw = Get-Content -Path $configFile -Raw -Encoding UTF8 -ErrorAction Stop

            return ($raw | ConvertFrom-Json -ErrorAction Stop)

        } catch { }

    }

    return $null

}



# Helper to find active forwarder processes scoped to task

function Get-ActiveForwarderProcesses {

    param(

        [string]$TaskName = "NotificationForwarder",

        $TaskInstance = $null

    )

    $procs = @()

    try {

        $taskTargetScript = $null

        if ($TaskInstance -and $TaskInstance.Actions) {

            $argStr = ($TaskInstance.Actions | ForEach-Object { $_.Arguments }) -join " "

            if ($argStr -match '(?i)-File\s+["'']?([^"'';\r\n]+)["'']?') {

                $taskTargetScript = $matches[1].Trim()

            } elseif ($argStr -match '(?i)["'']?([^"'';\r\n]+\.vbs)["'']?') {

                $taskVbs = $matches[1].Trim()

                $taskTargetScript = Join-Path (Split-Path $taskVbs -Parent) "NotificationForwarder.ps1"

            }

        }



        $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {

            $cmd = $_.CommandLine

            if (-not $cmd) { return $false }

            if ($cmd -like "*Recover-NotificationForwarder*" -or

                $cmd -like "*Test-NotificationForwarder*" -or

                $cmd -like "*Test-RecoverNotificationForwarder*" -or

                $cmd -like "*Test-WatchdogAlert*" -or

                $cmd -like "*Watchdog.ps1*") {

                return $false

            }



            # If supervising a custom or test task:

            if ($TaskName -ne "NotificationForwarder") {

                if ($taskTargetScript) {

                    return ($cmd -match [regex]::Escape($taskTargetScript))

                }

                return $false

            }



            # If supervising production "NotificationForwarder" task:

            $normScriptDir = ($scriptDir -replace '[\\/]+$', '')

            $prodScript = Join-Path -Path $normScriptDir -ChildPath "NotificationForwarder.ps1"

            if ($cmd -match [regex]::Escape($prodScript)) {

                return $true

            }

            return ($cmd -match '(?i)(?:^|[\s"''\\])NotificationForwarder\.ps1(?:[\s"'']|$)')

        })

    } catch {

        Write-Verbose "Could not query Win32_Process: $_"

    }



    foreach ($p in $procs) {

        $p

    }

}



# Dispatches failure alert using existing ntfy configuration and sender logic

function Send-WatchdogFailureAlert {

    [CmdletBinding()]

    param(

        [Parameter(Mandatory = $false)]

        $Config = $null,



        [Parameter(Mandatory = $false)]

        [scriptblock]$CustomHttpHandler = $null,



        [Parameter(Mandatory = $false)]

        [string]$AlertMessage = "NotificationForwarder needs attention. Automatic recovery failed.",



        [Parameter(Mandatory = $false)]

        [string]$AlertTitle = "Service Alert"

    )



    if (-not $Config) {

        $Config = Get-WatchdogConfig

    }



    if (-not $Config) {

        return @{

            Success = $false

            Error   = "Configuration could not be loaded."

        }

    }



    $topic = if ($Config -is [hashtable] -and $Config.ContainsKey("NtfyTopic")) { $Config["NtfyTopic"] } else { $Config.NtfyTopic }

    $server = if ($Config -is [hashtable] -and $Config.ContainsKey("NtfyServer")) { $Config["NtfyServer"] } else { $Config.NtfyServer }

    $token = if ($Config -is [hashtable] -and $Config.ContainsKey("NtfyToken")) { $Config["NtfyToken"] } else { $Config.NtfyToken }

    $dryRun = if ($Config -is [hashtable] -and $Config.ContainsKey("DryRun")) { $Config["DryRun"] } else { $Config.DryRun }

    $liveEnabled = if ($Config -is [hashtable] -and $Config.ContainsKey("LiveForwardingEnabled")) { $Config["LiveForwardingEnabled"] } else { $Config.LiveForwardingEnabled }



    if ([string]::IsNullOrWhiteSpace($topic)) {

        return @{

            Success = $false

            Error   = "NtfyTopic is not configured."

        }

    }



    if ([string]::IsNullOrWhiteSpace($server)) {

        $server = "https://ntfy.sh"

    }



    # Respect dry-run / safety gate if no custom mock handler is provided

    $isDryRun = ($dryRun -eq $true) -or ($liveEnabled -ne $true)

    if ($isDryRun -and -not $CustomHttpHandler) {

        Write-Verbose "[DRY-RUN] Live forwarding is disabled in config. Failure alert delivery simulated."

        return @{

            Success = $true

            Skipped = $true

            Reason  = "DryRun"

        }

    }



    $alertNotification = [PSCustomObject]@{

        AppLabel = "NotificationForwarder"

        Title    = $AlertTitle

        Body     = $AlertMessage

    }



    # Reuse Send-SingleAttempt from NotificationSender.ps1 if available

    if (Get-Command "Send-SingleAttempt" -ErrorAction SilentlyContinue) {

        try {

            $senderCfg = if ($Config -is [hashtable]) {

                $Config

            } else {

                @{

                    NtfyServer            = $server

                    NtfyTopic             = $topic

                    NtfyToken             = $token

                    DryRun                = $dryRun

                    LiveForwardingEnabled = $liveEnabled

                }

            }

            return Send-SingleAttempt `
                -FilteredNotification $alertNotification `
                -Config $senderCfg `
                -AttemptNumber 1 `
                -CustomHttpHandler $CustomHttpHandler

        } catch {

            $cleanErr = [regex]::Replace($_.Exception.Message, 'https?://[^\s]+', '<redacted-url>')

            return @{

                Success = $false

                Error   = $cleanErr

            }

        }

    }



    # Fallback direct HTTP post (strict secret scrubbing and 10s timeout)

    $topicUrl = "$($server.TrimEnd('/'))/$topic"

    $headers = @{

        "Title"    = "NotificationForwarder: $AlertTitle"

        "Priority" = "4"

        "Tags"     = "warning"

    }

    if (-not [string]::IsNullOrWhiteSpace($token)) {

        $headers["Authorization"] = "Bearer $token"

    }



    try {

        if ($CustomHttpHandler) {

            $null = & $CustomHttpHandler -Url $topicUrl -Headers $headers -Body $AlertMessage -Attempt 1

        } else {

            $bytes = [System.Text.Encoding]::UTF8.GetBytes($AlertMessage)

            $null = Invoke-RestMethod `
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

        $cleanError = [regex]::Replace($_.Exception.Message, 'https?://[^\s]+', '<redacted-url>')

        if (-not [string]::IsNullOrWhiteSpace($token)) {

            $cleanError = $cleanError.Replace($token, '<redacted-token>')

        }

        if (-not [string]::IsNullOrWhiteSpace($topic)) {

            $cleanError = $cleanError.Replace($topic, '<redacted-topic>')

        }

        return @{

            Success = $false

            Error   = $cleanError

        }

    }

}



# Network connectivity checker

function Test-InternetConnectivity {

    param(

        [Parameter(Mandatory = $false)]

        [string]$ServerUrl = "https://ntfy.sh",



        [Parameter(Mandatory = $false)]

        [int]$TimeoutSeconds = 3,



        [Parameter(Mandatory = $false)]

        [scriptblock]$CustomNetworkChecker = $null

    )



    if ($CustomNetworkChecker) {

        try {

            return [bool](& $CustomNetworkChecker)

        } catch {

            return $false

        }

    }



    try {

        $req = [System.Net.HttpWebRequest]::Create($ServerUrl)

        $req.Method = "HEAD"

        $req.Timeout = ($TimeoutSeconds * 1000)

        $req.ReadWriteTimeout = ($TimeoutSeconds * 1000)

        $resp = $req.GetResponse()

        $resp.Close()

        return $true

    } catch {

        # Secondary fallback in case primary ntfy host alone is glitching

        try {

            $req2 = [System.Net.HttpWebRequest]::Create("https://1.1.1.1")

            $req2.Method = "HEAD"

            $req2.Timeout = ($TimeoutSeconds * 1000)

            $req2.ReadWriteTimeout = ($TimeoutSeconds * 1000)

            $resp2 = $req2.GetResponse()

            $resp2.Close()

            return $true

        } catch {

            return $false

        }

    }

}



# Handles sustained internet outage tracking and recovery notification

function Invoke-WatchdogNetworkMonitoring {

    [CmdletBinding()]

    param(

        $Config,

        [string]$StatePath,

        [int]$OutageThreshold = 2,

        [scriptblock]$CustomNetworkChecker = $null,

        [scriptblock]$CustomHttpHandler = $null

    )



    $serverUrl = if ($Config -and $Config.NtfyServer) { $Config.NtfyServer } else { "https://ntfy.sh" }



    $isOnline = Test-InternetConnectivity `
        -ServerUrl $serverUrl `
        -TimeoutSeconds 3 `
        -CustomNetworkChecker $CustomNetworkChecker



    $networkRecoverySent = $false

    $networkAlertSkipped = $false

    $networkError = $null



    if (-not $isOnline) {

        # Network is DOWN

        $state = $null

        if (Test-Path $StatePath) {

            try {

                $raw = Get-Content -Path $StatePath -Raw -Encoding UTF8 -ErrorAction Stop

                $state = $raw | ConvertFrom-Json -ErrorAction Stop

            } catch { }

        }



        if (-not $state) {

            $state = @{

                ConsecutiveFailures = 1

                FirstFailedUtc      = (Get-Date).ToUniversalTime().ToString("o")

                OutageConfirmed     = ($OutageThreshold -le 1)

                RecoveryAlertSent   = $false

            }

            Write-WatchdogLog "[WARN] Internet connectivity check failed (ConsecutiveFailures=1)."

        } else {

            $prevFailures = if ($state.PSObject.Properties["ConsecutiveFailures"]) { [int]$state.ConsecutiveFailures } else { 0 }

            $newFailures = $prevFailures + 1

            $isConfirmed = ($newFailures -ge $OutageThreshold)

            $firstFailed = if ($state.PSObject.Properties["FirstFailedUtc"]) { [string]$state.FirstFailedUtc } else { (Get-Date).ToUniversalTime().ToString("o") }

            $state = @{

                ConsecutiveFailures = $newFailures

                FirstFailedUtc      = $firstFailed

                OutageConfirmed     = $isConfirmed

                RecoveryAlertSent   = $false

            }

            Write-WatchdogLog ("[WARN] Sustained internet outage in progress (ConsecutiveFailures={0}, OutageConfirmed={1})." -f $newFailures, $isConfirmed)

        }



        try {

            ($state | ConvertTo-Json -Compress) | Set-Content -Path $StatePath -Encoding UTF8 -Force

        } catch { }



        return [PSCustomObject]@{

            IsOnline             = $false

            NetworkRecoverySent  = $false

            NetworkAlertSkipped  = $false

            OutageConfirmed      = [bool]$state["OutageConfirmed"]

            ConsecutiveFailures  = [int]$state["ConsecutiveFailures"]

        }

    }



    # Network is ONLINE ($isOnline -eq $true)

    if (Test-Path $StatePath) {

        $state = $null

        try {

            $raw = Get-Content -Path $StatePath -Raw -Encoding UTF8 -ErrorAction Stop

            $state = $raw | ConvertFrom-Json -ErrorAction Stop

        } catch { }



        $outageConfirmed = if ($state -and $state.PSObject.Properties["OutageConfirmed"]) { [bool]$state.OutageConfirmed } else { $false }

        $alertAlreadySent = if ($state -and $state.PSObject.Properties["RecoveryAlertSent"]) { [bool]$state.RecoveryAlertSent } else { $false }



        if ($state -and $outageConfirmed -and -not $alertAlreadySent) {

            # A sustained outage just ended! Send recovery notification

            Write-WatchdogLog "Internet connectivity restored after sustained outage. Dispatching network recovery alert..."

            $alertRes = Send-WatchdogFailureAlert `
                -Config $Config `
                -CustomHttpHandler $CustomHttpHandler `
                -AlertMessage "Internet connection restored. NotificationForwarder is online." `
                -AlertTitle "Network Alert"



            if ($alertRes.Success) {

                $networkRecoverySent = $true

                Write-WatchdogLog "Network recovery alert delivered successfully to ntfy."

                Remove-Item -Path $StatePath -Force -ErrorAction SilentlyContinue

            } else {

                $networkError = $alertRes.Error

                Write-WatchdogLog ("[WARN] Could not deliver network recovery alert to ntfy: {0}" -f $networkError)

                # Mark alert sent/attempted in state file to avoid an infinite loop

                $updatedState = @{

                    ConsecutiveFailures = if ($state.PSObject.Properties["ConsecutiveFailures"]) { $state.ConsecutiveFailures } else { 1 }

                    FirstFailedUtc      = if ($state.PSObject.Properties["FirstFailedUtc"]) { $state.FirstFailedUtc } else { "" }

                    OutageConfirmed     = $true

                    RecoveryAlertSent   = $true

                    DeliveryError       = $networkError

                }

                try {

                    ($updatedState | ConvertTo-Json -Compress) | Set-Content -Path $StatePath -Encoding UTF8 -Force

                } catch { }

            }

        } elseif ($state -and -not $outageConfirmed) {

            # Brief fluctuation: resolved before reaching outage threshold

            Write-WatchdogLog "Internet connectivity verified. Brief fluctuation cleared without sending alert."

            Remove-Item -Path $StatePath -Force -ErrorAction SilentlyContinue

            $networkAlertSkipped = $true

        } else {

            # Recovery alert was already sent or state already cleared

            $networkAlertSkipped = $true

        }

    }



    return [PSCustomObject]@{

        IsOnline            = $true

        NetworkRecoverySent = $networkRecoverySent

        NetworkAlertSkipped = $networkAlertSkipped

        NetworkError        = $networkError

    }

}



# 1. Check if disabled intentionally

$task = Get-ScheduledTask -TaskName $ForwarderTaskName -ErrorAction SilentlyContinue



$isExplicitlyDisabled = $false

$disableReason = ""



if (Test-Path $disabledMarker) {

    $isExplicitlyDisabled = $true

    $disableReason = "marker file ($disabledMarker) is present"

} elseif ($task -and $task.State -eq 'Disabled') {

    $isExplicitlyDisabled = $true

    $disableReason = "task '$ForwarderTaskName' state is Disabled"

}



if ($isExplicitlyDisabled) {

    Write-Verbose "Forwarder is intentionally disabled ($disableReason). Watchdog taking no action."

    if ($PassThru.IsPresent) {

        return [PSCustomObject]@{

            Status      = "Disabled"

            Running     = $false

            ActionTaken = "None"

            Reason      = $disableReason

        }

    }

    return

}



# 2. Internet Connection Monitoring & Recovery Alerting

$netResult = $null

if (-not $DisableNetworkRecoveryAlert.IsPresent) {

    $netResult = Invoke-WatchdogNetworkMonitoring `
        -Config (Get-WatchdogConfig) `
        -StatePath $networkStateFile `
        -OutageThreshold $NetworkOutageThreshold `
        -CustomNetworkChecker $CustomNetworkChecker `
        -CustomHttpHandler $CustomHttpHandler

}



# 3. Check if target Scheduled Task exists

if (-not $task) {

    Write-WatchdogLog "[WARNING] Target task '$ForwarderTaskName' is not registered. Watchdog cannot supervise."

    if ($PassThru.IsPresent) {

        return [PSCustomObject]@{

            Status              = "NotRegistered"

            Running             = $false

            ActionTaken         = "None"

            Reason              = "Task not found"

            NetworkOnline       = if ($netResult) { $netResult.IsOnline } else { $null }

            NetworkRecoverySent = if ($netResult) { $netResult.NetworkRecoverySent } else { $false }

            NetworkAlertSkipped = if ($netResult) { $netResult.NetworkAlertSkipped } else { $false }

            NetworkError        = if ($netResult) { $netResult.NetworkError } else { $null }

        }

    }

    return

}



# 4. Check for active forwarder processes via Win32_Process

$activeProcesses = @(Get-ActiveForwarderProcesses -TaskName $ForwarderTaskName -TaskInstance $task)

$processIsRunning = ($activeProcesses.Count -gt 0)

$taskIsRunning = ($task.State -eq 'Running')



# 5. If already running, prevent duplicate start and reset any stale alert state

if ($processIsRunning -and -not $ForceRestart.IsPresent) {

    if (Test-Path $alertStateFile) {

        Remove-Item $alertStateFile -Force -ErrorAction SilentlyContinue

        Write-WatchdogLog "Forwarder process is healthy (PID $($activeProcesses[0].ProcessId)). Cleared prior alert state."

    }



    if ($PassThru.IsPresent) {

        return [PSCustomObject]@{

            Status              = "Running"

            Running             = $true

            ActionTaken         = "None"

            ProcessId           = $activeProcesses[0].ProcessId

            AlertStateCleared   = $true

            NetworkOnline       = if ($netResult) { $netResult.IsOnline } else { $null }

            NetworkRecoverySent = if ($netResult) { $netResult.NetworkRecoverySent } else { $false }

            NetworkAlertSkipped = if ($netResult) { $netResult.NetworkAlertSkipped } else { $false }

            NetworkError        = if ($netResult) { $netResult.NetworkError } else { $null }

        }

    }

    return

}



# 5. Recovery action: forwarder process is not running or restart is forced

Write-WatchdogLog ("Forwarder is not running (ProcessRunning={0}, TaskState={1}). Restarting task '{2}'..." -f $processIsRunning, $task.State, $ForwarderTaskName)



$recoveryFailed = $false

$failureReason = ""

$updatedState = "Unknown"

$verifiedPid = $null



try {

    # If Task Scheduler thinks it's still running but no process actually exists, stop it first to clear state

    if ($taskIsRunning -and -not $processIsRunning) {

        Write-Verbose "Clearing stale task state via Stop-ScheduledTask..."

        Stop-ScheduledTask -TaskName $ForwarderTaskName -ErrorAction SilentlyContinue

        Start-Sleep -Milliseconds 800

    }



    Start-ScheduledTask -TaskName $ForwarderTaskName -ErrorAction Stop

    Start-Sleep -Milliseconds 500



    $updatedTask = Get-ScheduledTask -TaskName $ForwarderTaskName -ErrorAction SilentlyContinue

    $updatedState = if ($updatedTask) { $updatedTask.State.ToString() } else { "Unknown" }

    Write-WatchdogLog ("Successfully signaled task '{0}' to start (Current state: {1})." -f $ForwarderTaskName, $updatedState)



    # Verification: Wait brief timeout and verify process is alive

    if ($RecoveryVerifySeconds -gt 0) {

        Start-Sleep -Seconds $RecoveryVerifySeconds

        $postVerifyProcs = @(Get-ActiveForwarderProcesses -TaskName $ForwarderTaskName -TaskInstance $task)

        if ($postVerifyProcs.Count -gt 0) {

            $verifiedPid = $postVerifyProcs[0].ProcessId

            Write-WatchdogLog ("Recovery verified: Forwarder process is running with PID {0}." -f $verifiedPid)



            # Reset prior alert state on successful recovery

            if (Test-Path $alertStateFile) {

                Remove-Item $alertStateFile -Force -ErrorAction SilentlyContinue

                Write-WatchdogLog "Recovery succeeded. Cleared prior failure alert state."

            }

        } else {

            $recoveryFailed = $true

            $failureReason = "No forwarder process detected after $RecoveryVerifySeconds seconds"

            Write-WatchdogLog ("[ERROR] Recovery verification failed: {0}." -f $failureReason)

        }

    }

} catch {

    $sanitizedError = [regex]::Replace($_.Exception.Message, 'https?://[^\s]+', '<redacted-url>')

    $recoveryFailed = $true

    $failureReason = "Failed to start task: $sanitizedError"

    Write-WatchdogLog ("[ERROR] Failed to start task '{0}': {1}" -f $ForwarderTaskName, $sanitizedError)

}



# 6. Service-Failure Alerting

$alertSent = $false

$alertSkipped = $false

$alertError = $null



if ($recoveryFailed -and -not $DisableAlert.IsPresent) {

    if (Test-Path $alertStateFile) {

        # Alert already dispatched for this incident

        $alertSkipped = $true

        Write-WatchdogLog "Recovery failed, but failure alert has already been sent for this incident. Suppressing duplicate alert."

    } else {

        # First failure for this incident: Dispatch alert

        Write-WatchdogLog "Recovery genuinely failed. Dispatching failure alert to ntfy..."

        try {

            $alertResult = Send-WatchdogFailureAlert `
                -Config (Get-WatchdogConfig) `
                -CustomHttpHandler $CustomHttpHandler



            $activeCfg = Get-WatchdogConfig

            if ($alertResult.Success) {

                $alertSent = $true

                $stateContent = [DateTime]::UtcNow.ToString("o") + "`r`nReason: " + $failureReason

                [System.IO.File]::WriteAllText($alertStateFile, $stateContent, [System.Text.Encoding]::UTF8)

                Write-WatchdogLog "Failure alert sent successfully to ntfy. Alert state recorded."

            } else {

                $alertError = $alertResult.Error

                if ($alertError -and (Get-Command "Get-SanitizedMessage" -ErrorAction SilentlyContinue)) {

                    $alertError = Get-SanitizedMessage -InputMessage $alertError -Config $activeCfg

                }

                Write-WatchdogLog ("[WARN] Could not deliver failure alert to ntfy: {0}" -f $alertError)

                # Persist incident state even if ntfy unreachable to prevent alert loops on subsequent runs

                $stateContent = [DateTime]::UtcNow.ToString("o") + "`r`nDeliveryAttempted: False`r`nError: " + $alertError

                [System.IO.File]::WriteAllText($alertStateFile, $stateContent, [System.Text.Encoding]::UTF8)

            }

        } catch {

            $alertError = [regex]::Replace($_.Exception.Message, 'https?://[^\s]+', '<redacted-url>')

            if ($activeCfg -and (Get-Command "Get-SanitizedMessage" -ErrorAction SilentlyContinue)) {

                $alertError = Get-SanitizedMessage -InputMessage $alertError -Config $activeCfg

            }

            Write-WatchdogLog ("[WARN] Exception dispatching failure alert: {0}" -f $alertError)

            $stateContent = [DateTime]::UtcNow.ToString("o") + "`r`nException: " + $alertError

            [System.IO.File]::WriteAllText($alertStateFile, $stateContent, [System.Text.Encoding]::UTF8)

        }

    }

}



if ($PassThru.IsPresent) {

    if ($failureReason -and $sanitizedError) {

        # Task start threw exception

        return [PSCustomObject]@{

            Status              = "Error"

            Running             = $false

            ActionTaken         = "Failed"

            Error               = $sanitizedError

            RecoverySuccess     = $false

            RecoveryStatus      = "Failed"

            AlertSent           = $alertSent

            AlertSkipped        = $alertSkipped

            AlertError          = $alertError

            NetworkOnline       = if ($netResult) { $netResult.IsOnline } else { $null }

            NetworkRecoverySent = if ($netResult) { $netResult.NetworkRecoverySent } else { $false }

            NetworkAlertSkipped = if ($netResult) { $netResult.NetworkAlertSkipped } else { $false }

            NetworkError        = if ($netResult) { $netResult.NetworkError } else { $null }

        }

    }



    return [PSCustomObject]@{

        Status              = "Restarted"

        Running             = (-not $recoveryFailed)

        ActionTaken         = "Start-ScheduledTask"

        TaskState           = $updatedState

        ProcessId           = $verifiedPid

        RecoverySuccess     = (-not $recoveryFailed)

        RecoveryStatus      = if (-not $recoveryFailed) { "Succeeded" } else { "Failed" }

        AlertSent           = $alertSent

        AlertSkipped        = $alertSkipped

        AlertError          = $alertError

        NetworkOnline       = if ($netResult) { $netResult.IsOnline } else { $null }

        NetworkRecoverySent = if ($netResult) { $netResult.NetworkRecoverySent } else { $false }

        NetworkAlertSkipped = if ($netResult) { $netResult.NetworkAlertSkipped } else { $false }

        NetworkError        = if ($netResult) { $netResult.NetworkError } else { $null }

    }

}

