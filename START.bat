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

echo  [1/3] Starting telemetry backend (PowerShell -Watch)...
start "CYBERFORTRESS_TELEMETRY" /MIN powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0backend\Get-SystemInfo.ps1" -Watch -Interval 3

echo  [2/3] Waiting for HTTP API to be ready...
powershell -NoProfile -NonInteractive -Command "& { $deadline=[DateTime]::Now.AddSeconds(20); while ([DateTime]::Now -lt $deadline) { $r=[System.Net.HttpWebRequest]::Create('http://localhost:7779/api/data'); $r.Timeout=1000; try { $r.GetResponse().Close(); exit 0 } catch {}; Start-Sleep -Milliseconds 500 }; exit 0 }"

:open_browser
echo  [3/3] Opening dashboard (data is ready)...
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
