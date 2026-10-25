@echo off
REM ============================================================
REM  Uninstall-Watchdog.bat
REM  Completely removes Watchdog: stops any running instance,
REM  removes the scheduled startup task and login-run entry,
REM  deletes the Desktop shortcut, and deletes C:\Watchdog plus
REM  its config/log data. Destructive - asks for confirmation.
REM ============================================================

setlocal
set "DEST=C:\Watchdog"

net session >nul 2>&1
if %errorlevel% == 0 goto :isAdmin

powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
exit /b

:isAdmin
REM If this copy is running from inside the folder we're about to delete, relaunch
REM a copy from %TEMP% first - deleting C:\Watchdog while running from inside it
REM can fail partway through, so we hop out of the folder before touching it.
REM (The small leftover copy in %TEMP% is harmless and gets cleaned up by Windows
REM  over time, so we don't try to self-delete it - not worth the fragile quoting.)
if /I "%~dp0"=="%DEST%\" (
    set "TEMPCOPY=%TEMP%\Uninstall-Watchdog-running.bat"
    copy /y "%~f0" "%TEMPCOPY%" >nul
    start "" cmd /c "%TEMPCOPY%"
    exit /b
)

echo ============================================================
echo  This will completely remove Watchdog from this computer:
echo    - Stop any running Watchdog process (GUI or headless)
echo    - Remove the scheduled startup task
echo    - Remove the "run at login" registry entry
echo    - Remove the Desktop shortcut
echo    - Delete %DEST% (the script, launcher, config and logs)
echo    - Delete saved settings under ProgramData and AppData
echo ============================================================
echo.
set /p CONFIRM="Type YES to continue, anything else to cancel: "
if /I not "%CONFIRM%"=="YES" (
    echo Cancelled. Nothing was changed.
    pause
    exit /b 0
)

echo.
echo Stopping any running Watchdog process...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process -Filter 'Name=''powershell.exe''' | Where-Object { $_.CommandLine -and $_.CommandLine -match 'Watchdog.ps1' } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }"

echo Removing scheduled startup task...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Stop-ScheduledTask -TaskName 'Watchdog' -ErrorAction SilentlyContinue } catch {}; try { Unregister-ScheduledTask -TaskName 'Watchdog' -Confirm:$false -ErrorAction SilentlyContinue } catch {}"

echo Removing "run at login" entry...
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "Watchdog" /f >nul 2>&1

echo Removing Desktop shortcut...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = [IO.Path]::Combine([Environment]::GetFolderPath('Desktop'), 'Watchdog.lnk'); if (Test-Path $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }"

echo Deleting %DEST% ...
if exist "%DEST%" rmdir /s /q "%DEST%"

echo Deleting saved settings and logs...
powershell -NoProfile -ExecutionPolicy Bypass -Command "foreach ($p in @((Join-Path $env:ProgramData 'Watchdog'), (Join-Path $env:APPDATA 'Watchdog'))) { if (Test-Path $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } }"

echo.
echo ============================================================
echo  Watchdog has been completely removed from this computer.
echo ============================================================
pause
exit /b 0
