@echo off
chcp 65001 >nul
title J AI Assistant Server
cd /d "%~dp0"

REM --- Request administrator rights (full system access) ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo [OK] Administrator privileges confirmed.
echo Starting J AI Assistant server on http://localhost:8080 ...
echo Press Ctrl+C to stop.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "server.ps1"

if errorlevel 1 (
    echo.
    echo Server exited with an error. Check messages above.
    echo.
    pause
)
