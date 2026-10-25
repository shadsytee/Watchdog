@echo off
REM ============================================================
REM  Run-Watchdog.bat
REM  Double-click this to launch Watchdog.ps1 as Administrator,
REM  without a console window left hanging around. Keep this
REM  .bat in the SAME folder as Watchdog.ps1.
REM ============================================================

setlocal
set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%Watchdog.ps1"

if not exist "%PS1%" (
    echo Could not find Watchdog.ps1 next to this .bat file.
    echo Expected it at: %PS1%
    echo.
    echo Make sure Run-Watchdog.bat and Watchdog.ps1 are in the same folder.
    pause
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% == 0 goto :isAdmin

powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
exit /b

:isAdmin
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PS1%"
exit
