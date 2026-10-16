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

rem Locate the NotificationForwarder project directory dynamically
set "SCRIPT_PATH=%~dp0Recover-NotificationForwarder.ps1"

if not exist "%SCRIPT_PATH%" (
    echo.
    echo ========================================================
    echo   [ERROR] Could not find Recover-NotificationForwarder.ps1!
    echo ========================================================
    echo Checked location:
    echo   - %~dp0Recover-NotificationForwarder.ps1
    echo.
    echo Please make sure the NotificationForwarder files are
    echo in the correct directory.
    echo.
    pause
    exit /b 1
)

echo ========================================================
echo   NotificationForwarder - Emergency Recovery Launcher
echo ========================================================
echo Script : "%SCRIPT_PATH%"
echo Time   : %DATE% %TIME%
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
echo ========================================================
echo Execution finished with Exit Code: %EXIT_CODE%
echo ========================================================
echo Press any key to close this window...
pause >nul
exit /b %EXIT_CODE%
