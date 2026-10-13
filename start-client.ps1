# ============================================
# J AI ASSISTANT - ЗАПУСК КЛИЕНТА
# Открывает клиентский интерфейс в браузере
# ============================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   J AI Assistant - Клиент" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$clientPath = Join-Path $ScriptDir "client.html"

if (Test-Path $clientPath) {
    Write-Host "Открываю клиентский интерфейс..." -ForegroundColor Green
    Start-Process $clientPath
    Write-Host "✅ Клиент открыт в браузере" -ForegroundColor Green
    Write-Host ""
    Write-Host "Убедитесь, что сервер запущен:" -ForegroundColor Yellow
    Write-Host "  .\server.ps1" -ForegroundColor Gray
    Write-Host ""
} else {
    Write-Host "❌ Файл client.html не найден!" -ForegroundColor Red
    Write-Host "Путь: $clientPath" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Нажмите любую клавишу для выхода..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
