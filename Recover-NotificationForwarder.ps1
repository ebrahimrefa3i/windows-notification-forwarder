<#

.SYNOPSIS

    Manual Emergency Recovery Script for NotificationForwarder.

.DESCRIPTION

    Diagnoses, validates, and recovers the NotificationForwarder service and its Watchdog.

    - Operates completely independently of the Watchdog.

    - Reuses the existing Task Scheduler configuration.

    - Prevents duplicate processes.

    - Never exposes sensitive notification content, tokens, or URLs.

#>



[CmdletBinding()]

param(

    [Parameter(Mandatory = $false)]

    [string]$ProjectDir = $null,



    [Parameter(Mandatory = $false)]

    [string]$ForwarderTaskName = "NotificationForwarder",



    [Parameter(Mandatory = $false)]

    [string]$WatchdogTaskName = "NotificationForwarder-Watchdog",



    [Parameter(Mandatory = $false)]

    [string]$LogPath = $null,



    [Parameter(Mandatory = $false)]

    [int]$StartupWaitSeconds = 3,



    [Parameter(Mandatory = $false)]

    [switch]$NonInteractive,



    [Parameter(Mandatory = $false)]

    [switch]$EnableWatchdogIfDisabled,



    [Parameter(Mandatory = $false)]

    [switch]$PassThru

)



# Resolve Project Directory

if ([string]::IsNullOrWhiteSpace($ProjectDir)) {

    $ProjectDir = $PSScriptRoot

    if ([string]::IsNullOrWhiteSpace($ProjectDir)) {

        $ProjectDir = (Get-Location).Path

    }

}



# Resolve Log Path

if ([string]::IsNullOrWhiteSpace($LogPath)) {

    $LogPath = Join-Path -Path $ProjectDir -ChildPath "forwarder.log"

} elseif (-not [System.IO.Path]::IsPathRooted($LogPath)) {

    $LogPath = Join-Path -Path $ProjectDir -ChildPath $LogPath

}



$disabledMarker = Join-Path -Path $ProjectDir -ChildPath ".disabled"



# Helper for formatted output

function Write-Header {

    param([string]$Title)

    Write-Host ""

    Write-Host "================================================================================" -ForegroundColor Cyan

    Write-Host "  $Title" -ForegroundColor Cyan

    Write-Host "================================================================================" -ForegroundColor Cyan

}



function Write-Section {

    param([string]$Title)

    Write-Host ""

    Write-Host "--- $Title ---" -ForegroundColor Yellow

}



function Write-StatusItem {

    param(

        [string]$Label,

        [string]$Value,

        [ConsoleColor]$Color = [ConsoleColor]::White

    )

    $pad = $Label.PadRight(28)

    Write-Host "  $pad : " -NoNewline -ForegroundColor Gray

    Write-Host "$Value" -ForegroundColor $Color

}



# Log Sanitizer: Redacts URLs, tokens, and notification payload fields

function Sanitize-LogLine {

    param([string]$Line)

    if ([string]::IsNullOrEmpty($Line)) { return $Line }



    # 1. Redact URLs (ntfy servers, topics, query strings)

    $sanitized = [regex]::Replace($Line, "https?://\S+", "<redacted-url>")



    # 2. Redact authorization headers, tokens, credentials

    $tokenPattern = "(?i)(bearer\s+|token\s*[:=]\s*|auth(?:orization)?\s*[:=]\s*|password\s*[:=]\s*|key\s*[:=]\s*|secret\s*[:=]\s*)\S+"

    $sanitized = [regex]::Replace($sanitized, $tokenPattern, "`$1<redacted>")



    # 3. Redact potential notification content (Title, Body, Message, Summary)

    $titlePattern = '(?i)(Title\s*[:=]\s*["'']?)[^"'';\r\n]+(["'']?)'

    $bodyPattern  = '(?i)(Body\s*[:=]\s*["'']?)[^"'';\r\n]+(["'']?)'

    $msgPattern   = '(?i)(Message\s*[:=]\s*["'']?)[^"'';\r\n]+(["'']?)'



    $sanitized = [regex]::Replace($sanitized, $titlePattern, '$1<redacted-title>$2')

    $sanitized = [regex]::Replace($sanitized, $bodyPattern,  '$1<redacted-body>$2')

    $sanitized = [regex]::Replace($sanitized, $msgPattern,   '$1<redacted-message>$2')



    return $sanitized

}



# Win32_Process Query for active Forwarder instances (strictly excluding watchdog, recovery, and test scripts)

function Get-ForwarderProcesses {

    param([string]$Dir = $null)

    try {

        $targetScript = if (-not [string]::IsNullOrWhiteSpace($Dir)) {

            Join-Path -Path $Dir -ChildPath "NotificationForwarder.ps1"

        } else { $null }



        $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {

            $cmd = $_.CommandLine

            if (-not $cmd) { return $false }

            

            # Exclude recovery script itself, test runners, and watchdog

            if ($cmd -like "*Recover-NotificationForwarder*" -or

                $cmd -like "*Test-NotificationForwarder*" -or

                $cmd -like "*Test-RecoverNotificationForwarder*" -or

                $cmd -like "*Watchdog.ps1*") {

                return $false

            }



            if ($targetScript) {

                # If a specific directory was provided, match that script's path

                if ($cmd -match [regex]::Escape($targetScript)) {

                    return $true

                }

                # If directory is production directory, also match general script call

                $normDir = ($Dir -replace '[\\/]+$', '')

                if ($cmd -match [regex]::Escape($normDir) -and ($cmd -match '(?i)(?:^|[\s"''\\])NotificationForwarder\.ps1(?:[\s"'']|$)')) {

                    return $true

                }

                return $false

            }



            # Must match NotificationForwarder.ps1 as an independent script invocation

            return ($cmd -match '(?i)(?:^|[\s"''\\])NotificationForwarder\.ps1(?:[\s"'']|$)')

        })



        foreach ($p in $procs) {

            $p

        }

    } catch {

        Write-Verbose "Win32_Process query error: $_"

    }

}



# Check existence of required project files

function Test-RequiredFiles {

    $required = @(

        "NotificationForwarder.ps1",

        "NotificationReader.ps1",

        "NotificationFilter.ps1",

        "NotificationSender.ps1",

        "Config.ps1",

        "config.json",

        "Watchdog.ps1",

        "Run-WatchdogHidden.vbs"

    )



    $results = @{}

    $allPresent = $true

    $missingList = @()



    foreach ($file in $required) {

        $fullPath = Join-Path -Path $ProjectDir -ChildPath $file

        $exists = Test-Path $fullPath

        $results[$file] = @{

            FullPath = $fullPath

            Exists   = $exists

        }

        if (-not $exists) {

            $allPresent = $false

            $missingList += $file

        }

    }



    return [PSCustomObject]@{

        AllPresent  = $allPresent

        Missing     = $missingList

        FileDetails = $results

    }

}



# ------------------------------------------------------------------------------

# EXECUTION BEGINS

# ------------------------------------------------------------------------------



$timestamp = [DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss")

Write-Header "NotificationForwarder - Emergency Diagnostic & Recovery"

Write-StatusItem "Timestamp" "$timestamp (Local)"

Write-StatusItem "Project Directory" $ProjectDir

Write-StatusItem "Forwarder Task" $ForwarderTaskName

Write-StatusItem "Watchdog Task" $WatchdogTaskName

Write-StatusItem "Diagnostic Log" $LogPath



# 1. Check Required Files

Write-Section "1. Required Files Verification"

$fileCheck = Test-RequiredFiles

foreach ($key in $fileCheck.FileDetails.Keys) {

    $info = $fileCheck.FileDetails[$key]

    if ($info.Exists) {

        Write-StatusItem $key "[EXISTS] $($info.FullPath)" -Color Green

    } else {

        Write-StatusItem $key "[MISSING] $($info.FullPath)" -Color Red

    }

}



if (-not $fileCheck.AllPresent) {

    Write-Host ""

    Write-Host "  [CRITICAL ERROR] One or more required project files are missing:" -ForegroundColor Red

    foreach ($m in $fileCheck.Missing) {

        Write-Host "    - $m" -ForegroundColor Red

    }

    Write-Host "  Cannot safely start or recover NotificationForwarder without complete files." -ForegroundColor Red



    if ($PassThru.IsPresent) {

        return [PSCustomObject]@{

            Status       = "MissingFiles"

            ActionTaken  = "Aborted"

            MissingFiles = $fileCheck.Missing

            LogPath      = $LogPath

        }

    }

    exit 2

}



# 2. Check Intentional Disable Marker

Write-Section "2. Intentional Service Marker"

$markerPresent = Test-Path $disabledMarker

if ($markerPresent) {

    Write-StatusItem "Disable Marker (.disabled)" "PRESENT (Service intentionally paused)" -Color Yellow

    if (-not $NonInteractive.IsPresent) {

        $answer = Read-Host "  Service is marked disabled. Remove '.disabled' and proceed with recovery? [Y/N]"

        if ($answer -match '^(y|yes)$') {

            Remove-Item $disabledMarker -Force -ErrorAction SilentlyContinue

            Write-Host "  [OK] Removed .disabled marker." -ForegroundColor Green

            $markerPresent = $false

        } else {

            Write-Host "  [INFO] Preserving .disabled marker. Recovery will take no action." -ForegroundColor Yellow

            if ($PassThru.IsPresent) {

                return [PSCustomObject]@{

                    Status      = "Disabled"

                    ActionTaken = "None"

                    Reason      = "Disable marker present"

                    LogPath     = $LogPath

                }

            }

            exit 0

        }

    } else {

        Write-Host "  [INFO] Non-interactive mode: Preserving .disabled marker. Recovery taking no action." -ForegroundColor Yellow

        if ($PassThru.IsPresent) {

            return [PSCustomObject]@{

                Status      = "Disabled"

                ActionTaken = "None"

                Reason      = "Disable marker present"

                LogPath     = $LogPath

            }

        }

        exit 0

    }

} else {

    Write-StatusItem "Disable Marker (.disabled)" "Absent (Normal operation)" -Color Green

}



# 3. Scheduled Tasks Status Check

Write-Section "3. Scheduled Tasks Status"

$fwdTask = Get-ScheduledTask -TaskName $ForwarderTaskName -ErrorAction SilentlyContinue

if ($fwdTask) {

    $fwdTaskState = $fwdTask.State.ToString()

    $fwdColor = if ($fwdTaskState -eq 'Running') { [ConsoleColor]::Green } elseif ($fwdTaskState -eq 'Ready') { [ConsoleColor]::Cyan } else { [ConsoleColor]::Red }

    Write-StatusItem "Forwarder Task ($ForwarderTaskName)" "Registered (State: $fwdTaskState)" -Color $fwdColor

} else {

    $fwdTaskState = "NotRegistered"

    Write-StatusItem "Forwarder Task ($ForwarderTaskName)" "NOT REGISTERED" -Color Red

}



$wdTask = Get-ScheduledTask -TaskName $WatchdogTaskName -ErrorAction SilentlyContinue

$wdTaskState = if ($wdTask) { $wdTask.State.ToString() } else { "NotRegistered" }

if ($wdTask) {

    $wdColor = if ($wdTaskState -in @('Ready', 'Running')) { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }

    Write-StatusItem "Watchdog Task ($WatchdogTaskName)" "Registered (State: $wdTaskState)" -Color $wdColor

} else {

    Write-StatusItem "Watchdog Task ($WatchdogTaskName)" "NOT REGISTERED" -Color Yellow

}



# 4. Active Forwarder Process Check

Write-Section "4. Process Monitor"

$activeProcesses = @(Get-ForwarderProcesses -Dir $ProjectDir)

$procCount = $activeProcesses.Count



if ($procCount -gt 1) {

    $pids = ($activeProcesses | ForEach-Object { $_.ProcessId }) -join ", "

    Write-StatusItem "Forwarder Processes" "AMBIGUOUS ($procCount instances found: PIDs $pids)" -Color Red

    Write-Host ""

    Write-Host "  [WARNING] Multiple forwarder processes detected!" -ForegroundColor Red

    Write-Host "  To prevent duplicate deliveries or conflicting state, recovery will NOT start another instance." -ForegroundColor Red

    Write-Host "  Please investigate or terminate stale processes manually before recovering." -ForegroundColor Red



    if ($PassThru.IsPresent) {

        return [PSCustomObject]@{

            Status       = "Ambiguous"

            ProcessCount = $procCount

            ProcessIds   = @($activeProcesses | ForEach-Object { $_.ProcessId })

            ActionTaken  = "None"

            LogPath      = $LogPath

        }

    }

    exit 3

} elseif ($procCount -eq 1) {

    $proc = $activeProcesses[0]

    Write-StatusItem "Forwarder Process" "RUNNING (PID: $($proc.ProcessId))" -Color Green

} else {

    Write-StatusItem "Forwarder Process" "STOPPED (No active process found)" -Color Yellow

}



# 5. Recent Sanitized Log Diagnostics

Write-Section "5. Recent Log Diagnostics"

if (Test-Path $LogPath) {

    try {

        $recentLines = @(Get-Content -Path $LogPath -Tail 50 -ErrorAction SilentlyContinue)

        $issues = @()

        foreach ($line in $recentLines) {

            if ($line -match '(?i)\[(ERROR|WARN|FATAL)\]|Exception|Failed') {

                $issues += (Sanitize-LogLine $line)

            }

        }



        if ($issues.Count -gt 0) {

            Write-Host "  Recent warning/error events (sanitized, max 5):" -ForegroundColor Yellow

            $displayCount = [Math]::Min($issues.Count, 5)

            for ($i = $issues.Count - $displayCount; $i -lt $issues.Count; $i++) {

                Write-Host "    $($issues[$i])" -ForegroundColor Gray

            }

        } else {

            Write-Host "  No obvious warnings or errors found in recent log entries." -ForegroundColor Green

        }

    } catch {

        Write-Host "  Could not read log file: $_" -ForegroundColor Yellow

    }

} else {

    Write-Host "  Log file not created yet: $LogPath" -ForegroundColor Gray

}



# 6. Watchdog Assessment & Explicit Option

Write-Section "6. Watchdog Assessment"

$watchdogActionTaken = "None"

if (-not $wdTask) {

    Write-Host "  [WARNING] Watchdog task '$WatchdogTaskName' is not registered." -ForegroundColor Yellow

    Write-Host "  To register it, run: Register-NotificationForwarderTask.ps1 -Register -WatchdogOnly" -ForegroundColor Gray

} elseif ($wdTaskState -eq 'Disabled') {

    Write-Host "  [WARNING] Watchdog task '$WatchdogTaskName' is currently DISABLED." -ForegroundColor Yellow

    $shouldEnableWd = $false



    if ($EnableWatchdogIfDisabled.IsPresent) {

        $shouldEnableWd = $true

    } elseif (-not $NonInteractive.IsPresent) {

        $answer = Read-Host "  Would you like to enable the Watchdog task now? [Y/N]"

        if ($answer -match '^(y|yes)$') {

            $shouldEnableWd = $true

        }

    }



    if ($shouldEnableWd) {

        try {

            Enable-ScheduledTask -TaskName $WatchdogTaskName -ErrorAction Stop | Out-Null

            Write-Host "  [OK] Successfully enabled Watchdog task '$WatchdogTaskName'." -ForegroundColor Green

            $watchdogActionTaken = "Enabled"

            $wdTaskState = "Ready"

        } catch {

            Write-Host "  [ERROR] Failed to enable Watchdog task: $_" -ForegroundColor Red

            $watchdogActionTaken = "EnableFailed"

        }

    } else {

        Write-Host "  [INFO] Watchdog task was left Disabled. Configuration was NOT modified." -ForegroundColor Gray

        Write-Host "  To enable it manually later, run: Register-NotificationForwarderTask.ps1 -Enable -WatchdogOnly" -ForegroundColor Gray

    }

} else {

    Write-Host "  [OK] Watchdog task is enabled and active (State: $wdTaskState)." -ForegroundColor Green

}



# 7. Recovery Evaluation

Write-Section "7. Service Recovery Action"



# Case A: Already Healthy

if ($procCount -ge 1 -and $fwdTask -and $fwdTaskState -ne 'Disabled') {

    Write-Host "  [OK] NotificationForwarder is healthy and running (PID: $($activeProcesses[0].ProcessId))." -ForegroundColor Green

    Write-Host "  No recovery action is necessary." -ForegroundColor Green

    Write-Host ""

    Write-Host "  Diagnostic Log: $LogPath" -ForegroundColor Cyan



    if ($PassThru.IsPresent) {

        return [PSCustomObject]@{

            Status               = "Healthy"

            ProcessCount         = $procCount

            ProcessId            = $activeProcesses[0].ProcessId

            TaskState            = $fwdTaskState

            WatchdogState        = $wdTaskState

            WatchdogAction       = $watchdogActionTaken

            ActionTaken          = "None"

            LogPath              = $LogPath

        }

    }

    exit 0

}



# Case B: Cannot Recover due to Missing Scheduled Task

if (-not $fwdTask) {

    Write-Host "  [ERROR] Scheduled task '$ForwarderTaskName' is not registered." -ForegroundColor Red

    Write-Host "  Cannot recover forwarder via Task Scheduler." -ForegroundColor Red

    Write-Host "  Please register the task first using: Register-NotificationForwarderTask.ps1 -Register" -ForegroundColor Yellow

    Write-Host ""

    Write-Host "  Diagnostic Log: $LogPath" -ForegroundColor Cyan



    if ($PassThru.IsPresent) {

        return [PSCustomObject]@{

            Status               = "NotRegistered"

            ProcessCount         = 0

            ActionTaken          = "Failed"

            Error                = "Scheduled task not found"

            LogPath              = $LogPath

        }

    }

    exit 4

}



# Case C: Forwarder Task is Disabled

if ($fwdTaskState -eq 'Disabled') {

    Write-Host "  [WARNING] Scheduled task '$ForwarderTaskName' is currently Disabled." -ForegroundColor Yellow

    $shouldEnableFwd = $false



    if (-not $NonInteractive.IsPresent) {

        $answer = Read-Host "  The Forwarder task is disabled. Would you like to enable and start it? [Y/N]"

        if ($answer -match '^(y|yes)$') {

            $shouldEnableFwd = $true

        }

    }



    if ($shouldEnableFwd) {

        try {

            Enable-ScheduledTask -TaskName $ForwarderTaskName -ErrorAction Stop | Out-Null

            Write-Host "  [OK] Enabled scheduled task '$ForwarderTaskName'." -ForegroundColor Green

            $fwdTaskState = "Ready"

        } catch {

            Write-Host "  [ERROR] Failed to enable forwarder task: $_" -ForegroundColor Red

            if ($PassThru.IsPresent) {

                return [PSCustomObject]@{

                    Status       = "Disabled"

                    ActionTaken  = "EnableFailed"

                    Error        = $_.Exception.Message

                    LogPath      = $LogPath

                }

            }

            exit 5

        }

    } else {

        Write-Host "  [ABORTED] Forwarder task remains Disabled. Recovery cannot proceed." -ForegroundColor Red

        Write-Host "  To enable it manually, run: Register-NotificationForwarderTask.ps1 -Enable -ForwarderOnly" -ForegroundColor Gray

        if ($PassThru.IsPresent) {

            return [PSCustomObject]@{

                Status      = "Disabled"

                ActionTaken = "None"

                LogPath     = $LogPath

            }

        }

        exit 5

    }

}



# Case D: Initiate Recovery via Existing Scheduled Task

Write-Host "  Forwarder is currently stopped. Initiating recovery..." -ForegroundColor Cyan



# Clear stale state if task scheduler thinks it's still running

if ($fwdTaskState -eq 'Running' -and $procCount -eq 0) {

    Write-Host "  Task state is 'Running' but no process exists. Resetting stale state..." -ForegroundColor Gray

    try {

        Stop-ScheduledTask -TaskName $ForwarderTaskName -ErrorAction SilentlyContinue

        Start-Sleep -Milliseconds 800

    } catch { }

}



# Trigger start through existing task

try {

    Write-Host "  Signaling Task Scheduler to start '$ForwarderTaskName'..." -ForegroundColor Cyan

    Start-ScheduledTask -TaskName $ForwarderTaskName -ErrorAction Stop

} catch {

    $err = [regex]::Replace($_.Exception.Message, 'https?://[^\s]+', '<redacted-url>')

    Write-Host "  [ERROR] Failed to trigger task '$ForwarderTaskName': $err" -ForegroundColor Red

    Write-Host ""

    Write-Host "  Diagnostic Log: $LogPath" -ForegroundColor Cyan



    if ($PassThru.IsPresent) {

        return [PSCustomObject]@{

            Status               = "TaskStartFailed"

            ProcessCount         = 0

            ActionTaken          = "StartAttempted"

            Error                = $err

            LogPath              = $LogPath

        }

    }

    exit 1

}



# Wait briefly and verify startup

Write-Host "  Waiting $StartupWaitSeconds second(s) for forwarder process to initialize..." -ForegroundColor Gray

Start-Sleep -Seconds $StartupWaitSeconds



$verifyProcesses = @(Get-ForwarderProcesses -Dir $ProjectDir)

if ($verifyProcesses.Count -eq 0) {

    # Give it one more brief check

    Start-Sleep -Seconds 2

    $verifyProcesses = @(Get-ForwarderProcesses -Dir $ProjectDir)

}



if ($verifyProcesses.Count -ge 1) {

    $newPid = $verifyProcesses[0].ProcessId

    Write-Host ""

    Write-Host "  ========================================================================" -ForegroundColor Green

    Write-Host "  [SUCCESS] NotificationForwarder was successfully recovered!" -ForegroundColor Green

    Write-Host "  Active Process PID: $newPid" -ForegroundColor Green

    Write-Host "  Task Scheduler State: $((Get-ScheduledTask -TaskName $ForwarderTaskName).State)" -ForegroundColor Green

    Write-Host "  Diagnostic Log:     $LogPath" -ForegroundColor Green

    Write-Host "  ========================================================================" -ForegroundColor Green



    if ($PassThru.IsPresent) {

        return [PSCustomObject]@{

            Status               = "Recovered"

            ProcessCount         = $verifyProcesses.Count

            ProcessId            = $newPid

            TaskState            = (Get-ScheduledTask -TaskName $ForwarderTaskName).State.ToString()

            WatchdogState        = $wdTaskState

            WatchdogAction       = $watchdogActionTaken

            ActionTaken          = "Start-ScheduledTask"

            LogPath              = $LogPath

        }

    }

    exit 0

} else {

    Write-Host ""

    Write-Host "  ========================================================================" -ForegroundColor Red

    Write-Host "  [FAILURE] Task was triggered, but no forwarder process was found!" -ForegroundColor Red

    Write-Host "  Please check the log file for startup or permission errors:" -ForegroundColor Red

    Write-Host "    $LogPath" -ForegroundColor Red

    Write-Host "  ========================================================================" -ForegroundColor Red



    if ($PassThru.IsPresent) {

        return [PSCustomObject]@{

            Status               = "StartupFailed"

            ProcessCount         = 0

            ActionTaken          = "StartAttempted"

            Error                = "No process detected after startup wait"

            LogPath              = $LogPath

        }

    }

    exit 1

}

