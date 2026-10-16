@echo off
setlocal

rem Verify PowerShell is available on PATH
where powershell.exe >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo.
    echo ========================================================
    echo   [ERROR] Windows PowerShell was not found on PATH!
    echo ========================================================
    echo Windows PowerShell is required to run NotificationForwarder.
    echo.
    pause
    exit /b 1
)

rem Locate the NotificationForwarder status script dynamically
set "SCRIPT_PATH=%~dp0Get-NotificationForwarderStatus.ps1"

if not exist "%SCRIPT_PATH%" (
    echo.
    echo ========================================================
    echo   [ERROR] Could not find Get-NotificationForwarderStatus.ps1!
    echo ========================================================
    echo Checked location:
    echo   - %~dp0Get-NotificationForwarderStatus.ps1
    echo.
    echo Please make sure the NotificationForwarder files are
    echo in the correct directory.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
echo ========================================================
echo Status check complete. Press any key to close this window...
echo ========================================================
pause >nul
exit /b %EXIT_CODE%
