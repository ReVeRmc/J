@echo off
chcp 65001 >nul
title J AI Assistant - Сервер
cd /d "%~dp0"

REM --- Запрос прав администратора (полный доступ к системе) ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo  Запрашиваю права администратора...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo  [OK] Права администратора подтверждены.
echo  Запуск сервера J AI Assistant...
echo.

powershell -ExecutionPolicy Bypass -File "server.ps1"

if errorlevel 1 (
    echo.
    echo  Ошибка запуска сервера.
    echo.
    pause
)
