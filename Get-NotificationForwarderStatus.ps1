<#

.SYNOPSIS

    Quick Status Report for NotificationForwarder.

.DESCRIPTION

    Inspects and displays the health of NotificationForwarder and its Watchdog.

    - Strictly READ-ONLY: never restarts, stops, or modifies any service, task, or file.

    - Sanitizes log lines to remove secrets and notification payloads.

    - Supports -PassThru for automated health checks and testing.

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

    [switch]$PassThru

)



$ErrorActionPreference = "Continue"



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



# Helper for formatted console output

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

        [string]$Color = "White"

    )

    $pad = $Label.PadRight(28)

    Write-Host "  $pad : " -NoNewline -ForegroundColor Gray

    Write-Host "$Value" -ForegroundColor $Color

}



# Log Sanitizer: Redacts URLs, tokens, and notification payload fields

function Sanitize-LogLine {

    param([string]$Line)

    if ([string]::IsNullOrEmpty($Line)) { return $Line }



    # 1. Redact URLs

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



# Win32_Process Query for active Forwarder instances (strictly excluding watchdog, recovery, status, and test scripts)

function Get-ActiveForwarderProcess {

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

                $cmd -like "*Test-NotificationForwarder*" -or

                $cmd -like "*Test-RecoverNotificationForwarder*" -or

                $cmd -like "*Test-WatchdogAlert*" -or

                $cmd -like "*Test-SprintFeatures*" -or

                $cmd -like "*Watchdog.ps1*") {

                return $false

            }



            if ($targetScript) {

                if ($cmd -match [regex]::Escape($targetScript)) {

                    return $true

                }

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



# 1. Required Files Check

$requiredFiles = @(

    "NotificationForwarder.ps1",

    "NotificationReader.ps1",

    "NotificationFilter.ps1",

    "NotificationSender.ps1",

    "Config.ps1",

    "config.json",

    "Watchdog.ps1",

    "Run-WatchdogHidden.vbs",

    "Run-ForwarderHidden.vbs"

)



$fileStatus = @{}

$missingFiles = @()

foreach ($file in $requiredFiles) {

    $p = Join-Path -Path $ProjectDir -ChildPath $file

    $exists = Test-Path -Path $p

    $fileStatus[$file] = $exists

    if (-not $exists) {

        $missingFiles += $file

    }

}

$allFilesPresent = ($missingFiles.Count -eq 0)



# 2. Configuration Inspection

$configData = @{

    PrivacyMode           = "Unknown"

    AppFilterMode         = "Unknown"

    LiveForwardingEnabled = $false

    DryRun                = $true

    AllowedAppCount       = 0

    BlockedAppCount       = 0

}



$cfgPath = Join-Path -Path $ProjectDir -ChildPath "config.json"

if (Test-Path -Path $cfgPath) {

    try {

        $raw = Get-Content -Path $cfgPath -Raw -Encoding UTF8 -ErrorAction Stop

        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop

        if ($parsed.PrivacyMode) { $configData.PrivacyMode = [string]$parsed.PrivacyMode }

        if ($parsed.AppFilterMode) { $configData.AppFilterMode = [string]$parsed.AppFilterMode }

        if ($null -ne $parsed.LiveForwardingEnabled) { $configData.LiveForwardingEnabled = [bool]$parsed.LiveForwardingEnabled }

        if ($null -ne $parsed.DryRun) { $configData.DryRun = [bool]$parsed.DryRun }

        if ($parsed.AllowedAppIds) { $configData.AllowedAppCount = @($parsed.AllowedAppIds).Count }

        if ($parsed.BlockedAppIds) {

            $configData.BlockedAppCount = @($parsed.BlockedAppIds).Count

        } elseif ($parsed.IgnoreAppIds) {

            $configData.BlockedAppCount = @($parsed.IgnoreAppIds).Count

        }

    } catch { }

}



# 3. Scheduled Tasks Check

$fwdTask = Get-ScheduledTask -TaskName $ForwarderTaskName -ErrorAction SilentlyContinue

$fwdTaskState = if ($fwdTask) { $fwdTask.State.ToString() } else { "Not Registered" }



$watchdogTask = Get-ScheduledTask -TaskName $WatchdogTaskName -ErrorAction SilentlyContinue

$watchdogTaskState = if ($watchdogTask) { $watchdogTask.State.ToString() } else { "Not Registered" }



# 4. Process Monitor Check

$fwdProcess = Get-ActiveForwarderProcess -Dir $ProjectDir

$processRunning = ($fwdProcess -ne $null)

$processId = if ($processRunning) { [int]$fwdProcess.ProcessId } else { $null }



# 5. Service Marker Check

$isServiceDisabled = Test-Path -Path $disabledMarker



# 6. Recent Log Diagnostics

$mostRecentError = $null

if (Test-Path -Path $LogPath) {

    try {

        $recentLines = Get-Content -Path $LogPath -Tail 60 -Encoding UTF8 -ErrorAction SilentlyContinue

        $errorLines = @($recentLines | Where-Object { $_ -match '\[(ERROR|WARN|FATAL)\]' })

        if ($errorLines.Count -gt 0) {

            $mostRecentError = Sanitize-LogLine -Line ($errorLines[-1].Trim())

        }

    } catch { }

}



# 7. Overall Health Determination

$attentionReasons = @()



if (-not $allFilesPresent) {

    $attentionReasons += ("Missing required file(s): " + ($missingFiles -join ", "))

}

if ($isServiceDisabled) {

    $attentionReasons += "Service is intentionally disabled via .disabled marker file"

}

if (-not $processRunning) {

    $attentionReasons += "NotificationForwarder background process is NOT running"

}

if (-not $fwdTask) {

    $attentionReasons += "Scheduled task '$ForwarderTaskName' is not registered"

} elseif ($fwdTaskState -eq "Disabled") {

    $attentionReasons += "Scheduled task '$ForwarderTaskName' is Disabled"

}

if (-not $watchdogTask) {

    $attentionReasons += "Watchdog scheduled task '$WatchdogTaskName' is not registered"

} elseif ($watchdogTaskState -eq "Disabled") {

    $attentionReasons += "Watchdog scheduled task '$WatchdogTaskName' is Disabled"

}



$isHealthy = ($attentionReasons.Count -eq 0)



# Console Output Presentation

if (-not $PassThru.IsPresent) {

    Write-Header "NotificationForwarder - Service Health & Status Report"

    $nowStr = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    Write-StatusItem "Timestamp" "$nowStr (Local)" "Gray"

    Write-StatusItem "Project Directory" $ProjectDir "Gray"

    Write-StatusItem "Diagnostic Log" $LogPath "Gray"



    Write-Section "1. Required Files Verification"

    foreach ($file in $requiredFiles) {

        $exists = $fileStatus[$file]

        $tag = if ($exists) { "[EXISTS]" } else { "[MISSING]" }

        $color = if ($exists) { "Green" } else { "Red" }

        Write-StatusItem $file "$tag $(Join-Path $ProjectDir $file)" $color

    }



    Write-Section "2. Service & Process Status"

    $procVal = if ($processRunning) { "RUNNING (PID: $processId)" } else { "STOPPED (No active process)" }

    $procColor = if ($processRunning) { "Green" } else { "Red" }

    Write-StatusItem "Forwarder Process" $procVal $procColor



    $fwdTaskColor = if ($fwdTaskState -in @("Running", "Ready")) { "Green" } else { "Red" }

    Write-StatusItem "Forwarder Task ($ForwarderTaskName)" $fwdTaskState $fwdTaskColor



    $wdTaskColor = if ($watchdogTaskState -in @("Running", "Ready")) { "Green" } else { "Red" }

    Write-StatusItem "Watchdog Task ($WatchdogTaskName)" $watchdogTaskState $wdTaskColor



    $markerVal = if ($isServiceDisabled) { "Present (Service intentionally stopped)" } else { "Absent (Normal operation)" }

    $markerColor = if ($isServiceDisabled) { "Yellow" } else { "Green" }

    Write-StatusItem "Disable Marker (.disabled)" $markerVal $markerColor



    Write-Section "3. Configuration & Privacy"

    $privColor = if ($configData.PrivacyMode -eq "TitleOnly") { "Green" } else { "Cyan" }

    Write-StatusItem "Privacy Mode" "$($configData.PrivacyMode)" $privColor



    $filterColor = if ($configData.AppFilterMode -eq "Allowlist") { "Green" } else { "Yellow" }

    Write-StatusItem "App Filter Mode" "$($configData.AppFilterMode) ($($configData.AllowedAppCount) allowed, $($configData.BlockedAppCount) blocked)" $filterColor



    $modeVal = if ($configData.LiveForwardingEnabled -and -not $configData.DryRun) {

        "LIVE FORWARDING (Active delivery to iPhone)"

    } else {

        "DRY-RUN (Safe simulation, live delivery disabled)"

    }

    $modeColor = if ($configData.LiveForwardingEnabled -and -not $configData.DryRun) { "Green" } else { "Yellow" }

    Write-StatusItem "Forwarding Mode" $modeVal $modeColor



    Write-Section "4. Recent Log Diagnostics"

    if ($mostRecentError) {

        Write-StatusItem "Most Recent Error/Warn" $mostRecentError "Yellow"

    } else {

        Write-StatusItem "Most Recent Error/Warn" "None (No recent errors recorded)" "Green"

    }



    Write-Section "5. Overall Health Assessment"

    if ($isHealthy) {

        Write-Host ""

        Write-Host "  ========================================================================" -ForegroundColor Green

        Write-Host "  [HEALTHY] NotificationForwarder is operational and actively protected." -ForegroundColor Green

        Write-Host "  ========================================================================" -ForegroundColor Green

    } else {

        Write-Host ""

        Write-Host "  ========================================================================" -ForegroundColor Red

        Write-Host "  [NEEDS ATTENTION] One or more issues require inspection:" -ForegroundColor Red

        foreach ($reason in $attentionReasons) {

            Write-Host "    - $reason" -ForegroundColor Yellow

        }

        Write-Host "  ========================================================================" -ForegroundColor Red

    }

    Write-Host ""

}



if ($PassThru.IsPresent) {

    return [PSCustomObject]@{

        IsHealthy             = $isHealthy

        ProcessRunning        = $processRunning

        ProcessId             = $processId

        ForwarderTaskState    = $fwdTaskState

        WatchdogTaskState     = $watchdogTaskState

        AllFilesPresent       = $allFilesPresent

        MissingFiles          = $missingFiles

        PrivacyMode           = $configData.PrivacyMode

        AppFilterMode         = $configData.AppFilterMode

        LiveForwardingEnabled = $configData.LiveForwardingEnabled

        DryRun                = $configData.DryRun

        MostRecentError       = $mostRecentError

        AttentionReasons      = $attentionReasons

    }

}

