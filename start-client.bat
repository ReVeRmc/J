@echo off
title J AI Assistant - Клиент
cd /d "%~dp0"

echo.
echo  Запуск клиента J AI Assistant...
echo.

powershell -ExecutionPolicy Bypass -File "start-client.ps1"

if errorlevel 1 (
    echo.
    echo  Ошибка запуска клиента.
    echo.
    pause
)
