@echo off
title J AI Assistant - Сервер
cd /d "%~dp0"

echo.
echo  Запуск сервера J AI Assistant...
echo.

powershell -ExecutionPolicy Bypass -File "server.ps1"

if errorlevel 1 (
    echo.
    echo  Ошибка запуска сервера.
    echo.
    pause
)
