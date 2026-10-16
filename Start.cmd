@echo off
setlocal

rem ========================================================
rem   NotificationForwarder - Connect Your iPhone Wizard
rem ========================================================

rem Verify PowerShell is available on PATH
where powershell.exe >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo.
    echo ========================================================
    echo   [ERROR] Windows PowerShell was not found on PATH!
    echo ========================================================
    echo Windows PowerShell is required to run NotificationForwarder.
    echo Please ensure PowerShell is installed and available in your PATH.
    echo.
    pause
    exit /b 1
)

rem Locate Setup-Wizard.ps1 dynamically relative to this launcher
set "SCRIPT_PATH=%~dp0Setup-Wizard.ps1"

if not exist "%SCRIPT_PATH%" (
    echo.
    echo ========================================================
    echo   [ERROR] Could not find Setup-Wizard.ps1!
    echo ========================================================
    echo Checked location:
    echo   - %~dp0Setup-Wizard.ps1
    echo.
    echo Please make sure the NotificationForwarder files are
    echo in the correct directory.
    echo.
    pause
    exit /b 1
)

echo Starting iPhone Setup Wizard...
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT_PATH%"
set "EXIT_CODE=%ERRORLEVEL%"

if %EXIT_CODE% neq 0 (
    echo.
    echo Setup Wizard exited with code %EXIT_CODE%.
    pause
)
exit /b %EXIT_CODE%
