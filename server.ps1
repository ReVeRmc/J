# ============================================
# J AI ASSISTANT - СЕРВЕРНАЯ ЧАСТЬ
# PowerShell сервер с AI логикой
# ============================================

param(
    [int]$Port = 8080,
    [string]$ServerHost = "localhost"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

# Глобальные переменные
$script:conversationHistory = @()
$script:context = @{
    topic = $null
    lastTopic = $null
    turnCount = 0
}

# База знаний
$script:knowledgeBase = @{
    "python" = @{
        text = "🐍 Python — высокоуровневый язык программирования с простым синтаксисом. Используется в Data Science, Machine Learning, веб-разработке и автоматизации."
        keywords = @("python", "питон")
    }
    "javascript" = @{
        text = "⚡ JavaScript — язык программирования для веба. Работает в браузерах и на сервере (Node.js). Самый популярный язык на GitHub."
        keywords = @("javascript", "js")
    }
    "ai" = @{
        text = "🤖 Искусственный интеллект — область компьютерных наук, создающая системы, способные выполнять задачи, требующие человеческого интеллекта. Включает машинное обучение, нейронные сети, обработку естественного языка."
        keywords = @("искусственный интеллект", "ai", "ии")
    }
    "machine_learning" = @{
        text = "🧠 Машинное обучение — подраздел AI, позволяющий компьютерам учиться на данных. Типы: обучение с учителем, без учителя, с подкреплением."
        keywords = @("машинное обучение", "ml")
    }
    "neural_networks" = @{
        text = "🧬 Нейронные сети — математические модели, вдохновлённые биологическим мозгом. Типы: CNN (изображения), RNN (последовательности), Transformer (текст)."
        keywords = @("нейронные сети", "нейросети")
    }
}

function Write-ServerLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry -ForegroundColor $(
        switch ($Level) {
            "INFO" { "Cyan" }
            "SUCCESS" { "Green" }
            "ERROR" { "Red" }
            "WARNING" { "Yellow" }
            default { "White" }
        }
    )
}

function Get-AIResponse {
    param(
        [string]$UserText,
        [hashtable]$Context
    )
    
    $lower = $UserText.ToLower()
    
    # Приветствия
    if ($lower -match "^(привет|здравствуй|хай|hello)\b") {
        $hour = (Get-Date).Hour
        $greeting = if ($hour -lt 12) { "Доброе утро" } elseif ($hour -lt 18) { "Добрый день" } else { "Добрый вечер" }
        return "$greeting! Я J — ваш AI-ассистент. Чем могу помочь?"
    }
    
    # Время
    if ($lower -match "который час|время|дата|сегодня") {
        $now = Get-Date
        return "📅 $($now.ToString('dd.MM.yyyy'))`n⏰ $($now.ToString('HH:mm:ss'))"
    }
    
    # Благодарность
    if ($lower -match "^(спасибо|благодар|отлично|супер)\b") {
        return "Всегда рад помочь! 😊"
    }
    
    # Прощание
    if ($lower -match "^(пока|до свидания|бай)\b") {
        return "До встречи! 👋"
    }
    
    # Поиск в базе знаний
    foreach ($key in $script:knowledgeBase.Keys) {
        $entry = $script:knowledgeBase[$key]
        foreach ($keyword in $entry.keywords) {
            if ($lower -match $keyword) {
                # Обновляем контекст
                $script:context.lastTopic = $script:context.topic
                $script:context.topic = $key
                return $entry.text
            }
        }
    }
    
    # Дефолтный ответ
    return "Я вас понял. Задайте вопрос о программировании, AI, машинном обучении или нейронных сетях. Или просто поговорите со мной!"
}

function Process-Request {
    param(
        [string]$UserInput,
        [hashtable]$Context = @{}
    )
    
    Write-ServerLog "Получен запрос: $UserInput"
    
    # Служебный ping от клиента (проверка подключения) — не попадает в историю
    if ($UserInput -eq "ping") {
        return @{
            response = "pong"
            context = $script:context
        }
    }

    # Обновляем контекст
    $script:conversationHistory += @{
        role = "user"
        content = $UserInput
        timestamp = Get-Date
    }
    
    $script:context.turnCount++
    
    # Обработка через AI
    $response = Get-AIResponse -UserText $UserInput -Context $script:context
    
    # Добавляем ответ в историю
    $script:conversationHistory += @{
        role = "assistant"
        content = $response
        timestamp = Get-Date
    }
    
    Write-ServerLog "Отправлен ответ: $($response.Substring(0, [Math]::Min(50, $response.Length)))..."
    
    return @{
        response = $response
        context = $script:context
    }
}

function Start-Server {
    Write-ServerLog "Запуск сервера J AI Assistant..." "SUCCESS"
    Write-ServerLog "Сервер доступен на http://$($ServerHost):$Port" "SUCCESS"
    Write-ServerLog "Нажмите Ctrl+C для остановки" "WARNING"
    Write-Host ""
    
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://$($ServerHost):$Port/")
    
    try {
        $listener.Start()
        Write-ServerLog "Сервер запущен и ожидает подключений..." "SUCCESS"
        
        while ($listener.IsListening) {
            $context = $listener.GetContext()
            $request = $context.Request
            $response = $context.Response
            
            Write-ServerLog "Получен запрос от $($request.RemoteEndPoint)"
            
            try {
                # CORS-заголовки (клиент открывается как file://, браузер шлёт preflight-запросы)
                $response.AddHeader("Access-Control-Allow-Origin", "*")
                $response.AddHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
                $response.AddHeader("Access-Control-Allow-Headers", "Content-Type")

                # Статическая раздача клиента: http://localhost:8080/ -> client.html
                if ($request.HttpMethod -eq "GET") {
                    $clientFile = Join-Path $ScriptDir "client.html"
                    if (Test-Path $clientFile) {
                        $htmlBytes = [System.IO.File]::ReadAllBytes($clientFile)
                        $response.ContentType = "text/html; charset=utf-8"
                        $response.ContentLength64 = $htmlBytes.Length
                        $response.OutputStream.Write($htmlBytes, 0, $htmlBytes.Length)
                    } else {
                        $response.StatusCode = 404
                    }
                    $response.OutputStream.Close()
                    continue
                }

                # Ответ на preflight-запрос браузера
                if ($request.HttpMethod -eq "OPTIONS") {
                    $response.StatusCode = 204
                    $response.OutputStream.Close()
                    continue
                }

                # Читаем тело запроса
                $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                $body = $reader.ReadToEnd()
                $reader.Close()
                
                # Парсим JSON
                $requestData = $body | ConvertFrom-Json
                
                # Обрабатываем запрос
                $result = Process-Request -UserInput $requestData.message -Context @{}
                
                # Формируем ответ
                $responseData = @{
                    success = $true
                    response = $result.response
                    context = $result.context
                    timestamp = Get-Date -Format "o"
                } | ConvertTo-Json -Depth 10
                
                # Отправляем ответ
                $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($responseData)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $responseBytes.Length
                $response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
                
                Write-ServerLog "Ответ отправлен успешно" "SUCCESS"
                
            } catch {
                Write-ServerLog "Ошибка обработки запроса: $_" "ERROR"
                
                $errorResponse = @{
                    success = $false
                    error = $_.Exception.Message
                    timestamp = Get-Date -Format "o"
                } | ConvertTo-Json
                
                $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($errorResponse)
                $response.StatusCode = 500
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $responseBytes.Length
                $response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
            }
            
            $response.OutputStream.Close()
        }
        
    } catch {
        Write-ServerLog "Критическая ошибка сервера: $_" "ERROR"
    } finally {
        if ($listener.IsListening) {
            $listener.Stop()
        }
        $listener.Close()
        Write-ServerLog "Сервер остановлен" "WARNING"
    }
}

# Запуск сервера
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   J AI Assistant - Серверная часть" -ForegroundColor Cyan
Write-Host "   Версия 2.3" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Start-Server
