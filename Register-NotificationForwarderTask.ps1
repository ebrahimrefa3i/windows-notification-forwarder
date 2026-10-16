<#



.SYNOPSIS



    Manages the Windows Scheduled Tasks for the NotificationForwarder project.



.DESCRIPTION



    Creates, inspects, starts, stops, disables, enables, and removes:



    1. NotificationForwarder: Primary daemon starting at Windows logon with continuous execution and auto-restart.



    2. NotificationForwarder-Watchdog: Periodic supervisor running every minute to ensure the daemon is running.



    Both tasks run under the interactive user logon session without elevated privileges.



#>



[CmdletBinding()]



param(



    [Parameter(Mandatory = $false)]



    [switch]$Register,



    [Parameter(Mandatory = $false)]



    [switch]$Inspect,



    [Parameter(Mandatory = $false)]



    [switch]$Start,



    [Parameter(Mandatory = $false)]



    [switch]$Stop,



    [Parameter(Mandatory = $false)]



    [switch]$Disable,



    [Parameter(Mandatory = $false)]



    [switch]$Enable,



    [Parameter(Mandatory = $false)]



    [switch]$Unregister,



    [Parameter(Mandatory = $false)]



    [switch]$WatchdogOnly,



    [Parameter(Mandatory = $false)]



    [switch]$ForwarderOnly,



    [Parameter(Mandatory = $false)]



    [switch]$Restart,



    [Parameter(Mandatory = $false)]



    [switch]$ShowCommand,



    [Parameter(Mandatory = $false)]



    [string]$ProjectDirectory



)



$ErrorActionPreference = "Stop"



$taskName = "NotificationForwarder"



$watchdogTaskName = "NotificationForwarder-Watchdog"



if (-not [string]::IsNullOrWhiteSpace($ProjectDirectory) -and (Test-Path $ProjectDirectory)) {



    $scriptDir = (Resolve-Path $ProjectDirectory).Path



} elseif (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {



    $scriptDir = (Resolve-Path $PSScriptRoot).Path



} else {



    $scriptDir = (Get-Location).Path



}



$forwarderScript = Join-Path -Path $scriptDir -ChildPath "NotificationForwarder.ps1"



$watchdogScript = Join-Path -Path $scriptDir -ChildPath "Watchdog.ps1"



$forwarderLauncher = Join-Path -Path $scriptDir -ChildPath "Run-ForwarderHidden.vbs"



$watchdogLauncher = Join-Path -Path $scriptDir -ChildPath "Run-WatchdogHidden.vbs"



$logPath = Join-Path -Path $scriptDir -ChildPath "forwarder.log"



$disabledMarker = Join-Path -Path $scriptDir -ChildPath ".disabled"



$forwarderArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$forwarderScript`" -LogPath `"$logPath`""



$forwarderLauncherArgs = "`"$forwarderLauncher`""



$watchdogArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchdogScript`" -LogPath `"$logPath`""



$watchdogLauncherArgs = "`"$watchdogLauncher`""



function Write-ServiceLog {



    param([string]$Message)



    try {



        $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ssZ")



        $line = "[$timestamp] [SERVICE] $Message"



        [System.IO.File]::AppendAllText($logPath, "$line`r`n", [System.Text.Encoding]::UTF8)



    } catch { }



}



Write-Host "==========================================================" -ForegroundColor Cyan



Write-Host "  NotificationForwarder - Windows Task Scheduler Manager" -ForegroundColor Cyan



Write-Host "==========================================================" -ForegroundColor Cyan



# 1. Register Action



if ($Register.IsPresent) {



    $principal = New-ScheduledTaskPrincipal `
        -UserId $env:USERNAME `
        -LogonType Interactive `
        -RunLevel Limited



    if (-not $WatchdogOnly.IsPresent) {



        Write-Host "[CONFIG] Registering primary task '$taskName'..." -ForegroundColor Cyan



        if (Test-Path $forwarderLauncher) {



            $forwarderAction = New-ScheduledTaskAction `
                -Execute "wscript.exe" `
                -Argument $forwarderLauncherArgs `
                -WorkingDirectory $scriptDir



            $actionDisplay = "wscript.exe $forwarderLauncherArgs"



        } else {



            $forwarderAction = New-ScheduledTaskAction `
                -Execute "powershell.exe" `
                -Argument $forwarderArgs `
                -WorkingDirectory $scriptDir



            $actionDisplay = "powershell.exe $forwarderArgs"



        }



        $forwarderTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME



        $forwarderSettings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -RestartCount 999 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit ([TimeSpan]::Zero)



    $null = Register-ScheduledTask `
        -TaskName $taskName `
        -Action $forwarderAction `
        -Trigger $forwarderTrigger `
        -Settings $forwarderSettings `
        -Principal $principal `
        -Description "Windows-to-iPhone Notification Forwarder background daemon" `
        -Force



    Write-Host "[SUCCESS] Task '$taskName' registered to start at user logon." -ForegroundColor Green



    Write-Host "  Action:         $actionDisplay" -ForegroundColor Gray



    Write-Host "  Log File:       $logPath" -ForegroundColor Gray



    Write-Host "  User:           $env:USERNAME (Interactive / Limited privileges)" -ForegroundColor Gray



    Write-Host "  Crash Recovery: 999 retries every 1m, continuous execution (no limit)" -ForegroundColor Gray



    }



    Write-Host "`n[CONFIG] Registering watchdog supervisor task '$watchdogTaskName'..." -ForegroundColor Cyan



    $watchdogAction = New-ScheduledTaskAction `
        -Execute "wscript.exe" `
        -Argument $watchdogLauncherArgs `
        -WorkingDirectory $scriptDir



    $watchdogLogonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME



    $watchdogRepeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 9999)



    $watchdogRepeatTrigger.Repetition.StopAtDurationEnd = $false



    $watchdogSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5)



    $null = Register-ScheduledTask `
        -TaskName $watchdogTaskName `
        -Action $watchdogAction `
        -Trigger @($watchdogLogonTrigger, $watchdogRepeatTrigger) `
        -Settings $watchdogSettings `
        -Principal $principal `
        -Description "Supervises NotificationForwarder daemon; restarts it if stopped unexpectedly" `
        -Force



    Write-Host "[SUCCESS] Watchdog task '$watchdogTaskName' registered." -ForegroundColor Green



    Write-Host "  Action:         wscript.exe $watchdogLauncherArgs" -ForegroundColor Gray



    Write-Host "  Triggers:       At user logon + Every 1 minute indefinitely" -ForegroundColor Gray



    Write-Host "  Crash Recovery: Active watchdog supervision enabled" -ForegroundColor Gray



    return



}



# 2. Inspect Action



if ($Inspect.IsPresent) {



    Write-Host "`n--- PRIMARY DAEMON TASK: $taskName ---" -ForegroundColor White



    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue



    if (-not $task) {



        Write-Host "  Status: NOT currently registered." -ForegroundColor Yellow



    } else {



        $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue



        Write-Host "  Status: Registered" -ForegroundColor Green



        Write-Host ("  Task State:       {0}" -f $task.State) -ForegroundColor $(if ($task.State -eq 'Running') { "Green" } elseif ($task.State -eq 'Ready') { "Yellow" } else { "Gray" })



        Write-Host ("  Action:           {0} {1}" -f $task.Actions.Execute, $task.Actions.Arguments) -ForegroundColor White



        Write-Host ("  Working Directory:{0}" -f $task.Actions.WorkingDirectory) -ForegroundColor White



        Write-Host ("  User Account:     {0}" -f $task.Principal.UserId) -ForegroundColor White



        Write-Host ("  Execution Limit:  {0}" -f $task.Settings.ExecutionTimeLimit) -ForegroundColor White



        Write-Host ("  Restart Policy:   {0} retries every {1}" -f $task.Settings.RestartCount, $task.Settings.RestartInterval) -ForegroundColor White



        Write-Host ("  MultipleInstances:{0}" -f $task.Settings.MultipleInstances) -ForegroundColor White



        Write-Host ("  Last Run Time:    {0}" -f $info.LastRunTime) -ForegroundColor White



        Write-Host ("  Last Result Code: {0}" -f $info.LastTaskResult) -ForegroundColor White



        Write-Host ("  Next Run Time:    {0}" -f $info.NextRunTime) -ForegroundColor White



    }



    Write-Host "`n--- WATCHDOG SUPERVISOR TASK: $watchdogTaskName ---" -ForegroundColor White



    $wTask = Get-ScheduledTask -TaskName $watchdogTaskName -ErrorAction SilentlyContinue



    if (-not $wTask) {



        Write-Host "  Status: NOT currently registered." -ForegroundColor Yellow



    } else {



        $wInfo = Get-ScheduledTaskInfo -TaskName $watchdogTaskName -ErrorAction SilentlyContinue



        Write-Host "  Status: Registered" -ForegroundColor Green



        Write-Host ("  Task State:       {0}" -f $wTask.State) -ForegroundColor $(if ($wTask.State -eq 'Running') { "Green" } elseif ($wTask.State -eq 'Ready') { "Yellow" } else { "Gray" })



        Write-Host ("  Action:           {0} {1}" -f $wTask.Actions.Execute, $wTask.Actions.Arguments) -ForegroundColor White



        Write-Host ("  Triggers:         {0} trigger(s) configured" -f $wTask.Triggers.Count) -ForegroundColor White



        Write-Host ("  Last Run Time:    {0}" -f $wInfo.LastRunTime) -ForegroundColor White



        Write-Host ("  Last Result Code: {0}" -f $wInfo.LastTaskResult) -ForegroundColor White



        Write-Host ("  Next Run Time:    {0}" -f $wInfo.NextRunTime) -ForegroundColor White



    }



    Write-Host "`n--- ACTIVE PROCESS MONITOR ---" -ForegroundColor White



    $activeForwarder = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {



        $_.CommandLine -and $_.CommandLine -match '(?<!Test-)NotificationForwarder\.ps1' -and $_.CommandLine -notlike "*Test-NotificationForwarder.ps1*" -and $_.CommandLine -notlike "*Watchdog.ps1*"



    })



    if ($activeForwarder.Count -gt 0) {



        foreach ($p in $activeForwarder) {



            Write-Host ("  Forwarder Process: RUNNING (PID={0}, ProcessId={0})" -f $p.ProcessId) -ForegroundColor Green



        }



    } else {



        Write-Host "  Forwarder Process: NOT RUNNING" -ForegroundColor Yellow



    }



    $activeWatchdog = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {



        $_.CommandLine -and $_.CommandLine -like "*Watchdog.ps1*"



    })



    if ($activeWatchdog.Count -gt 0) {



        foreach ($wp in $activeWatchdog) {



            Write-Host ("  Watchdog Process:  RUNNING (PID={0})" -f $wp.ProcessId) -ForegroundColor Green



        }



    } else {



        Write-Host "  Watchdog Process:  IDLE (Periodic timer triggered)" -ForegroundColor Gray



    }



    Write-Host "`n--- SERVICE STATE ---" -ForegroundColor White



    $markerExists = Test-Path $disabledMarker



    $isForwarderDisabled = ($task -and $task.State -eq 'Disabled')



    $isWatchdogDisabled = ($wTask -and $wTask.State -eq 'Disabled')



    if ($markerExists -or $isForwarderDisabled -or $isWatchdogDisabled) {



        Write-Host "  Mode: INTENTIONALLY DISABLED" -ForegroundColor Yellow



        Write-Host ("  Disabled Marker (.disabled): {0}" -f $(if ($markerExists) { "Present" } else { "Not Present" })) -ForegroundColor Gray



        Write-Host ("  Forwarder Task Disabled:     {0}" -f $isForwarderDisabled) -ForegroundColor Gray



        Write-Host ("  Watchdog Task Disabled:      {0}" -f $isWatchdogDisabled) -ForegroundColor Gray



    } else {



        Write-Host "  Mode: ENABLED (Active/Ready for startup)" -ForegroundColor Green



    }



    Write-Host "`n--- DIAGNOSTIC LOG: forwarder.log ---" -ForegroundColor White



    if (Test-Path $logPath) {



        $logFile = Get-Item $logPath



        Write-Host ("  Log File:     {0}" -f $logPath) -ForegroundColor White



        Write-Host ("  File Size:    {0:N0} bytes" -f $logFile.Length) -ForegroundColor White



        Write-Host ("  Last Written: {0}" -f $logFile.LastWriteTime) -ForegroundColor White



        Write-Host "  Recent Log Lines (last 5):" -ForegroundColor Gray



        Get-Content $logPath -Tail 5 | ForEach-Object {



            Write-Host ("    $_") -ForegroundColor Gray



        }



    } else {



        Write-Host "  Log File: Does not exist yet (will be created on first launch)" -ForegroundColor Gray



    }



    return



}



# 2b. Restart Action



if ($Restart.IsPresent) {



    if (Test-Path $disabledMarker) {



        Remove-Item $disabledMarker -Force -ErrorAction SilentlyContinue



        Write-Host "[CONFIG] Removed .disabled marker file." -ForegroundColor Gray



    }



    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue



    if (-not $task) {



        Write-Host "[ERROR] Task '$taskName' is not registered." -ForegroundColor Red



        return



    }



    Write-Host "[RESTART] Stopping running instance of '$taskName'..." -ForegroundColor Yellow



    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue



    $lingering = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {



        $_.CommandLine -and $_.CommandLine -match '(?<!Test-)NotificationForwarder\.ps1' -and $_.CommandLine -notlike "*Test-NotificationForwarder.ps1*" -and $_.CommandLine -notlike "*Watchdog.ps1*"



    })



    foreach ($p in $lingering) {



        try {



            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue



            Write-Host ("  Stopped forwarder PID={0}" -f $p.ProcessId) -ForegroundColor Gray



        } catch { }



    }



    Start-Sleep -Milliseconds 1200



    if ($task.State -eq 'Disabled') {



        Enable-ScheduledTask -TaskName $taskName



        Write-Host "[CONFIG] Enabled task '$taskName'." -ForegroundColor Gray



    }



    Start-ScheduledTask -TaskName $taskName



    Write-Host "[SUCCESS] Primary task '$taskName' restarted cleanly." -ForegroundColor Green



    Write-ServiceLog "Primary task '$taskName' restarted by user command."



    return



}



# 3. Start Action



if ($Start.IsPresent) {



    if (Test-Path $disabledMarker) {



        Remove-Item $disabledMarker -Force -ErrorAction SilentlyContinue



        Write-Host "[CONFIG] Removed .disabled marker file." -ForegroundColor Gray



    }



    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue



    if (-not $task) {



        Write-Host "[ERROR] Task '$taskName' is not registered. Run with -Register first." -ForegroundColor Red



        return



    }



    if ($task.State -eq 'Disabled') {



        Enable-ScheduledTask -TaskName $taskName



        Write-Host "[CONFIG] Enabled task '$taskName'." -ForegroundColor Gray



    }



    $wTask = Get-ScheduledTask -TaskName $watchdogTaskName -ErrorAction SilentlyContinue



    if ($wTask -and $wTask.State -eq 'Disabled') {



        Enable-ScheduledTask -TaskName $watchdogTaskName



        Write-Host "[CONFIG] Enabled watchdog task '$watchdogTaskName'." -ForegroundColor Gray



    }



    Start-ScheduledTask -TaskName $taskName



    Write-Host "[SUCCESS] Task '$taskName' signaled to start." -ForegroundColor Green



    if ($wTask) {



        Start-ScheduledTask -TaskName $watchdogTaskName



        Write-Host "[SUCCESS] Watchdog task '$watchdogTaskName' signaled to start." -ForegroundColor Green



    }



    Write-ServiceLog "NotificationForwarder and Watchdog started by user command."



    return



}



# 4. Stop Action



if ($Stop.IsPresent) {



    $wTask = Get-ScheduledTask -TaskName $watchdogTaskName -ErrorAction SilentlyContinue



    if ($wTask) {



        Stop-ScheduledTask -TaskName $watchdogTaskName -ErrorAction SilentlyContinue



        Write-Host "[SUCCESS] Watchdog task '$watchdogTaskName' stopped." -ForegroundColor Yellow



    }



    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue



    if ($task) {



        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue



        Write-Host "[SUCCESS] Task '$taskName' stopped." -ForegroundColor Yellow



    }



    # Stop any running powershell process executing NotificationForwarder.ps1



    $lingering = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {



        $_.CommandLine -and $_.CommandLine -match '(?<!Test-)NotificationForwarder\.ps1' -and $_.CommandLine -notlike "*Test-NotificationForwarder.ps1*" -and $_.CommandLine -notlike "*Watchdog.ps1*"



    })



    foreach ($p in $lingering) {



        try {



            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue



            Write-Host ("  Terminated lingering process PID={0}" -f $p.ProcessId) -ForegroundColor Gray



        } catch { }



    }



    # Stop any lingering wscript hidden forwarder launcher



    $lingeringWscript = @(Get-CimInstance Win32_Process -Filter "Name = 'wscript.exe'" -ErrorAction SilentlyContinue | Where-Object {



        $_.CommandLine -and $_.CommandLine -match 'Run-ForwarderHidden\.vbs'



    })



    foreach ($p in $lingeringWscript) {



        try {



            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue



            Write-Host ("  Terminated lingering launcher PID={0}" -f $p.ProcessId) -ForegroundColor Gray



        } catch { }



    }



    Write-ServiceLog "NotificationForwarder stopped by user command."



    return



}



# 5. Disable Action



if ($Disable.IsPresent) {



    # Place .disabled sentinel marker



    [System.IO.File]::WriteAllText($disabledMarker, "disabled at $([DateTime]::UtcNow.ToString('o'))`r`n", [System.Text.Encoding]::UTF8)



    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue



    if ($task) {



        Disable-ScheduledTask -TaskName $taskName



        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue



    }



    $wTask = Get-ScheduledTask -TaskName $watchdogTaskName -ErrorAction SilentlyContinue



    if ($wTask) {



        Disable-ScheduledTask -TaskName $watchdogTaskName



        Stop-ScheduledTask -TaskName $watchdogTaskName -ErrorAction SilentlyContinue



    }



    # Stop any active forwarder processes



    $lingering = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {



        $_.CommandLine -and $_.CommandLine -match '(?<!Test-)NotificationForwarder\.ps1' -and $_.CommandLine -notlike "*Test-NotificationForwarder.ps1*" -and $_.CommandLine -notlike "*Watchdog.ps1*"



    })



    foreach ($p in $lingering) {



        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { }



    }



    Write-ServiceLog "NotificationForwarder and Watchdog intentionally disabled by user."



    Write-Host "[SUCCESS] Both NotificationForwarder and Watchdog have been DISABLED." -ForegroundColor Yellow



    Write-Host "  Automatic startup at logon is disabled." -ForegroundColor Gray



    Write-Host "  Watchdog recovery checks are suspended." -ForegroundColor Gray



    Write-Host "  Marker file created: $disabledMarker" -ForegroundColor Gray



    return



}



# 6. Enable Action



if ($Enable.IsPresent) {



    if (Test-Path $disabledMarker) {



        Remove-Item $disabledMarker -Force -ErrorAction SilentlyContinue



    }



    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue



    if ($task) {



        Enable-ScheduledTask -TaskName $taskName



    }



    $wTask = Get-ScheduledTask -TaskName $watchdogTaskName -ErrorAction SilentlyContinue



    if ($wTask) {



        Enable-ScheduledTask -TaskName $watchdogTaskName



    }



    Write-ServiceLog "NotificationForwarder and Watchdog re-enabled by user."



    Write-Host "[SUCCESS] Both NotificationForwarder and Watchdog have been RE-ENABLED." -ForegroundColor Green



    Write-Host "  Tasks are ready to start at next Windows logon." -ForegroundColor Gray



    Write-Host "  Run with -Start to launch immediately without waiting for logon." -ForegroundColor Gray



    return



}



# 7. Unregister Action



if ($Unregister.IsPresent) {



    # Stop running instances first



    $wTask = Get-ScheduledTask -TaskName $watchdogTaskName -ErrorAction SilentlyContinue



    if ($wTask) {



        Stop-ScheduledTask -TaskName $watchdogTaskName -ErrorAction SilentlyContinue



        Unregister-ScheduledTask -TaskName $watchdogTaskName -Confirm:$false



        Write-Host "[SUCCESS] Task '$watchdogTaskName' removed." -ForegroundColor Green



    }



    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue



    if ($task) {



        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue



        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false



        Write-Host "[SUCCESS] Task '$taskName' removed." -ForegroundColor Green



    }



    # Clean up marker



    if (Test-Path $disabledMarker) {



        Remove-Item $disabledMarker -Force -ErrorAction SilentlyContinue



    }



    # Terminate any lingering forwarder processes



    $lingering = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {



        $_.CommandLine -and $_.CommandLine -match '(?<!Test-)NotificationForwarder\.ps1' -and $_.CommandLine -notlike "*Test-NotificationForwarder.ps1*" -and $_.CommandLine -notlike "*Watchdog.ps1*"



    })



    foreach ($p in $lingering) {



        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { }



    }



    Write-ServiceLog "NotificationForwarder and Watchdog unregistered and removed."



    Write-Host "[SUCCESS] All NotificationForwarder scheduled tasks and processes removed." -ForegroundColor Green



    return



}



# Default / ShowCommand Display



$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue



$currentStatus = if ($existing) { $existing.State.ToString() } else { "Not Registered" }



Write-Host "`nCurrent Forwarder Status: $currentStatus" -ForegroundColor $(if ($currentStatus -eq 'Running') { "Green" } elseif ($currentStatus -eq 'Ready') { "Yellow" } else { "Gray" })



Write-Host "`nAvailable Management Switches:" -ForegroundColor White



Write-Host "  -Register    Create/update both tasks (-WatchdogOnly to update only watchdog)" -ForegroundColor Gray



Write-Host "  -Inspect     Display detailed runtime status, process check, and recent logs" -ForegroundColor Gray



Write-Host "  -Start       Start the forwarder and watchdog tasks immediately" -ForegroundColor Gray



Write-Host "  -Stop        Stop running tasks and clean up forwarder processes" -ForegroundColor Gray



Write-Host "  -Disable     Disable automatic startup and watchdog recovery without removing tasks" -ForegroundColor Gray



Write-Host "  -Enable      Re-enable automatic startup and watchdog recovery" -ForegroundColor Gray



Write-Host "  -Unregister  Completely remove both scheduled tasks" -ForegroundColor Gray



Write-Host "  -ShowCommand Display the exact standalone PowerShell registration commands" -ForegroundColor Gray



Write-Host "`nStandalone PowerShell Commands:" -ForegroundColor Cyan



Write-Host @"



# Primary Forwarder Task (Runs silently in background via wscript.exe GUI subsystem)



`$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument '$forwarderLauncherArgs' -WorkingDirectory '$scriptDir'



`$trigger = New-ScheduledTaskTrigger -AtLogOn -User `$env:USERNAME



`$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)



`$principal = New-ScheduledTaskPrincipal -UserId `$env:USERNAME -LogonType Interactive -RunLevel Limited



Register-ScheduledTask -TaskName '$taskName' -Action `$action -Trigger `$trigger -Settings `$settings -Principal `$principal -Description 'Windows-to-iPhone Notification Forwarder background daemon' -Force



# Watchdog Supervisor Task



`$wAction = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument '$watchdogLauncherArgs' -WorkingDirectory '$scriptDir'



`$wLogonTrigger = New-ScheduledTaskTrigger -AtLogOn -User `$env:USERNAME



`$wRepeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 9999)



`$wRepeatTrigger.Repetition.StopAtDurationEnd = `$false



`$wSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)



Register-ScheduledTask -TaskName '$watchdogTaskName' -Action `$wAction -Trigger @(`$wLogonTrigger, `$wRepeatTrigger) -Settings `$wSettings -Principal `$principal -Description 'Supervises NotificationForwarder daemon; restarts it if stopped unexpectedly' -Force



"@ -ForegroundColor Green



