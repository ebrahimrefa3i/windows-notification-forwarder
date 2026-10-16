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

rem Locate the NotificationForwarder Dashboard script dynamically
set "SCRIPT_PATH=%~dp0Start-Dashboard.ps1"

if not exist "%SCRIPT_PATH%" (
    echo.
    echo ========================================================
    echo   [ERROR] Could not find Start-Dashboard.ps1!
    echo ========================================================
    echo Checked location:
    echo   - %~dp0Start-Dashboard.ps1
    echo.
    echo Please make sure the NotificationForwarder files are
    echo in the correct directory.
    echo.
    pause
    exit /b 1
)

echo Starting NotificationForwarder Dashboard...
echo [INFO] NotificationForwarder runs silently in the background.
echo [INFO] You can safely close this terminal window at any time without stopping forwarding.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" -OpenBrowser
set "EXIT_CODE=%ERRORLEVEL%"

if %EXIT_CODE% neq 0 (
    echo.
    echo Dashboard server exited with code %EXIT_CODE%.
    pause
)
exit /b %EXIT_CODE%
