@echo off
chcp 65001 >nul
title CYBERFORTRESS // LAUNCHER
cd /d "%~dp0"

echo.
echo  ====================================================
echo    CYBERFORTRESS // SYSTEM CONTROL  -  LAUNCHER
echo  ====================================================
echo.

REM kill any orphaned watcher
taskkill /FI "WINDOWTITLE eq CYBERFORTRESS_TELEMETRY*" /F >nul 2>&1

REM remove stale snapshot
if exist "%~dp0data\system-data.js" del /Q "%~dp0data\system-data.js" >nul 2>&1

echo  [1/3] Starting telemetry in background (PowerShell -Watch)...
start "CYBERFORTRESS_TELEMETRY" /MIN powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0backend\Get-SystemInfo.ps1" -Watch -Interval 3

echo  [2/3] Opening dashboard (auto-loads on first snapshot)...
timeout /t 1 /nobreak >nul
start "" "%~dp0frontend\index.html"

echo.
echo  ----------------------------------------------------
echo   Dashboard is live. Auto-refreshes every 3 seconds.
echo.
echo   To STOP telemetry, press any key in this window.
echo  ----------------------------------------------------
echo.
pause >nul

:cleanup
echo  Stopping telemetry...
taskkill /FI "WINDOWTITLE eq CYBERFORTRESS_TELEMETRY*" /F >nul 2>&1
echo  Done.
timeout /t 1 >nul
exit /b 0
