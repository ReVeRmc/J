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
    lastFile = $null      # активный файл для диалога о коде (поддерживает "измени строку 5" и т.п.)
    lastCommand = $null   # последняя выполненная команда (для "повтори", "отмени")
    lastDiff = $null      # последний diff для отмены изменения
}

# Пути логирования
$script:logDir = Join-Path $ScriptDir "logs"
if (-not (Test-Path $script:logDir)) { New-Item -ItemType Directory -Path $script:logDir | Out-Null }
$script:dialogLogFile = Join-Path $script:logDir "dialog.jsonl"       # полный лог диалога (JSON Lines)
$script:actionsLogFile = Join-Path $script:logDir "actions.log"       # лог всех действий с файлами/программами

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

# Логирование действий с файлами/программами на ПК (в файл + консоль)
function Write-ActionLog {
    param([string]$Action, [string]$Target, [string]$Result)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Action] Target: $Target | Result: $Result"
    try {
        Add-Content -Path $script:actionsLogFile -Value $line -Encoding UTF8
    } catch { }
    Write-ServerLog "ДЕЙСТВИЕ: $Action -> $Target" "SUCCESS"
}

# Полный лог активного диалога в JSON Lines (каждая реплика — отдельная запись)
function Write-DialogLog {
    param([string]$Role, [string]$Content, [string]$Intent = $null)
    $entry = @{
        timestamp = (Get-Date -Format "o")
        turn      = $script:context.turnCount
        role      = $Role
        intent    = $Intent
        content   = $Content
    } | ConvertTo-Json -Compress -Depth 5
    try {
        Add-Content -Path $script:dialogLogFile -Value $entry -Encoding UTF8
    } catch { }
}

# ============================================
# МОДУЛЬ РАБОТЫ С ФАЙЛАМИ И ПРОГРАММАМИ НА ПК
# Все операции логируются в logs/actions.log
# ============================================

$script:allowedDirs = @($ScriptDir, ([Environment]::GetFolderPath("Desktop")), ([Environment]::GetFolderPath("Documents")))

function Resolve-SafePath {
    # Возвращает полный путь только внутри разрешённых директорий (защита от выхода за пределы)
    param([string]$RawPath)
    if ([string]::IsNullOrWhiteSpace($RawPath)) { return $null }
    $candidate = if ([System.IO.Path]::IsPathRooted($RawPath)) { $RawPath } else { Join-Path (Get-Location).Path $RawPath }
    try { $full = [System.IO.Path]::GetFullPath($candidate) } catch { return $null }
    foreach ($dir in $script:allowedDirs) {
        if ($full -like "$($dir.TrimEnd('\'))\*" -or $full -eq $dir) { return $full }
    }
    return $null
}

function Get-FileInfoText {
    param([System.IO.FileInfo]$Fi)
    $sizeKB = [math]::Round($Fi.Length / 1KB, 2)
    return "📄 $($Fi.Name)`nПуть: $($Fi.FullName)`nРазмер: $sizeKB KB`nИзменён: $($Fi.LastWriteTime.ToString('dd.MM.yyyy HH:mm:ss'))"
}

function Invoke-FileOperation {
    param([hashtable]$Op)  # @{ action; path; ... }
    $action = $Op.action
    $path = Resolve-SafePath $Op.path
    if (-not $path) { return "⛔ Путь недоступен или запрещён (разрешены: папка проекта, Рабочий стол, Документы)." }

    switch ($action) {
        "list" {
            $dirPath = if ($Op.path) { $path } else { (Get-Location).Path }
            if (-not (Test-Path $dirPath -PathType Container)) { return "❌ Папка не найдена: $dirPath" }
            $items = Get-ChildItem $dirPath | Sort-Object PSIsContainer -Descending
            if ($items.Count -eq 0) { return "📂 Папка пуста: $dirPath" }
            $lines = $items | ForEach-Object {
                if ($_.PSIsContainer) { "📁 $($_.Name)/" } else { "📄 $($_.Name)  ($([math]::Round($_.Length/1KB,1)) KB)" }
            }
            Write-ActionLog "LIST_DIR" $dirPath "Найдено объектов: $($items.Count)"
            return ("📂 $dirPath`n" + ($lines -join "`n"))
        }
        "read" {
            if (-not (Test-Path $path -PathType Leaf)) { return "❌ Файл не найден: $path" }
            $fi = Get-Item $path
            if ($fi.Length -gt 64KB) { return "⚠️ Файл слишком большой для показа (>64KB): $($fi.Name)" }
            $content = Get-Content $path -Raw -Encoding UTF8
            if ($content.Length -gt 4000) { $content = $content.Substring(0, 4000) + "`n...[обрезано]" }
            $script:context.lastFile = $path
            Write-ActionLog "READ_FILE" $path "Прочитано $([math]::Round($fi.Length/1KB,1)) KB"
            return (Get-FileInfoText $fi) + "`n------`n$content"
        }
        "write" {
            $dir = Split-Path $path -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $existed = Test-Path $path -PathType Leaf
            $old = if ($existed) { Get-Content $path -Raw -Encoding UTF8 } else { $null }
            Set-Content -Path $path -Value $Op.content -Encoding UTF8 -NoNewline
            $script:context.lastFile = $path
            $script:context.lastDiff = @{ path = $path; old = $old }
            Write-ActionLog $(if ($existed) {"OVERRIDE_FILE"} else {"CREATE_FILE"}) $path "Записано $($Op.content.Length) симв."
            return $(if ($existed) {"✅ Файл перезаписан: $($fi = Get-Item $path; $fi.Name)"} else {"✅ Файл создан: $path"}) + "`n(можно «отменить»)"
        }
        "append" {
            if (-not (Test-Path $path -PathType Leaf)) { return "❌ Файл не найден: $path" }
            Add-Content -Path $path -Value $Op.content -Encoding UTF8
            $script:context.lastFile = $path
            Write-ActionLog "APPEND_FILE" $path "Добавлено $($Op.content.Length) симв."
            return "✅ Текст добавлен в конец файла: $path"
        }
        "replace" {
            if (-not (Test-Path $path -PathType Leaf)) { return "❌ Файл не найден: $path" }
            $content = Get-Content $path -Raw -Encoding UTF8
            if ($content -notmatch [regex]::Escape($Op.find)) { return "❌ Не найдено совпадений: «$($Op.find)»" }
            $count = ([regex]::Matches($content, [regex]::Escape($Op.find))).Count
            $script:context.lastDiff = @{ path = $path; old = $content }
            $newContent = $content.Replace($Op.find, $Op.replace)
            Set-Content -Path $path -Value $newContent -Encoding UTF8 -NoNewline
            $script:context.lastFile = $path
            Write-ActionLog "REPLACE_IN_FILE" $path "Заменено вхождений: $count («$($Op.find)» -> «$($Op.replace)»)"
            return "✅ Заменено $count вхождений в $(Split-Path $path -Leaf): «$($Op.find)» → «$($Op.replace)»`n(можно «отменить»)"
        }
        "delete" {
            if (-not (Test-Path $path)) { return "❌ Не найдено: $path" }
            Remove-Item $path -Recurse -Force
            Write-ActionLog "DELETE" $path "Удалено"
            return "🗑️ Удалено: $path"
        }
        "mkdir" {
            if (Test-Path $path) { return "ℹ️ Уже существует: $path" }
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            Write-ActionLog "MKDIR" $path "Создана папка"
            return "✅ Папка создана: $path"
        }
        "move" {
            if (-not (Test-Path $path)) { return "❌ Источник не найден: $path" }
            $dest = Resolve-SafePath $Op.dest
            if (-not $dest) { return "⛔ Недопустимый путь назначения." }
            Move-Item -Path $path -Destination $dest -Force
            Write-ActionLog "MOVE" "$path -> $dest" "Перемещено"
            return "✅ Перемещено: $path → $dest"
        }
        "copy" {
            if (-not (Test-Path $path)) { return "❌ Источник не найден: $path" }
            $dest = Resolve-SafePath $Op.dest
            if (-not $dest) { return "⛔ Недопустимый путь назначения." }
            Copy-Item -Path $path -Destination $dest -Recurse -Force
            Write-ActionLog "COPY" "$path -> $dest" "Скопировано"
            return "✅ Скопировано: $path → $dest"
        }
        "search" {
            $pattern = $Op.pattern
            $root = if ($Op.path) { $path } else { (Get-Location).Path }
            if (-not (Test-Path $root)) { return "❌ Папка не найдена: $root" }
            $found = Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -like "*$pattern*" } | Select-Object -First 30
            Write-ActionLog "SEARCH" "$root (*$pattern*)" "Найдено: $($found.Count)"
            if (-not $found -or $found.Count -eq 0) { return "🔍 Ничего не найдено по шаблону: *$pattern*" }
            return ("🔍 Найдено $($found.Count):`n" + (($found | ForEach-Object { "📄 $($_.FullName)" }) -join "`n"))
        }
        "info" {
            if (-not (Test-Path $path)) { return "❌ Не найдено: $path" }
            $item = Get-Item $path
            if ($item.PSIsContainer) {
                $cnt = (Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue).Count
                Write-ActionLog "INFO" $path "Папка, файлов: $cnt"
                return "📁 Папка: $path`nФайлов внутри: $cnt"
            }
            Write-ActionLog "INFO" $path "Файл, $($item.Length) байт"
            return Get-FileInfoText $item
        }
    }
    return "❌ Неизвестная операция: $action"
}

function Undo-LastChange {
    $d = $script:context.lastDiff
    if (-not $d -or -not $d.path) { return "ℹ️ Нет изменений для отмены." }
    if ($null -eq $d.old) {
        # файл был создан — удаляем
        if (Test-Path $d.path) { Remove-Item $d.path -Force; Write-ActionLog "UNDO_DELETE_CREATED" $d.path "Отменено создание" }
        $script:context.lastDiff = $null
        return "↩️ Отменено: файл удалён ($($d.path))"
    }
    Set-Content -Path $d.path -Value $d.old -Encoding UTF8 -NoNewline
    Write-ActionLog "UNDO_RESTORE" $d.path "Восстановлено предыдущее содержимое"
    $script:context.lastDiff = $null
    return "↩️ Отменено: файл восстановлен ($($d.path))"
}

# Запуск программ и команд (с белым списком опасных паттернов)
function Invoke-SystemCommand {
    param([string]$CommandLine)
    if ($CommandLine -match "(?i)(rm\s+-rf|format\s+[a-z]:|del\s+/s|shutdown|diskpart|reg\s+delete|mkfs|\bdel\b.*\\\*|:\(\)\{)") {
        Write-ActionLog "BLOCKED_CMD" $CommandLine "Заблокировано политикой безопасности"
        return "⛔ Команда заблокирована: потенциально опасная операция."
    }
    $script:context.lastCommand = $CommandLine
    Write-ServerLog "Выполняю команду: $CommandLine" "WARNING"
    try {
        $output = & cmd.exe /c $CommandLine 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        $trimmed = if ($output.Length -gt 3000) { $output.Substring(0, 3000) + "`n...[обрезано]" } else { $output }
        if ([string]::IsNullOrWhiteSpace($trimmed)) { $trimmed = "(нет текстового вывода)" }
        Write-ActionLog "RUN_CMD" $CommandLine "Код возврата: $exitCode"
        return "🖥️ Команда: $CommandLine`nКод возврата: $exitCode`n------`n$trimmed"
    } catch {
        Write-ActionLog "RUN_CMD_FAIL" $CommandLine $_.Exception.Message
        return "❌ Ошибка выполнения: $($_.Exception.Message)"
    }
}

function Open-ProgramOrFile {
    param([string]$Target)
    try {
        Start-Process $Target
        Write-ActionLog "OPEN" $Target "Запущено"
        return "🚀 Запущено: $Target"
    } catch {
        Write-ActionLog "OPEN_FAIL" $Target $_.Exception.Message
        return "❌ Не удалось запустить «$Target»: $($_.Exception.Message)"
    }
}

function Get-SystemStatus {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $memTotalGB = if ($os) { [math]::Round($os.TotalVisibleMemorySize / 1MB, 1) } else { "?" }
    $memFreeGB  = if ($os) { [math]::Round($os.FreePhysicalMemory / 1MB, 1) } else { "?" }
    $procs = (Get-Process -ErrorAction SilentlyContinue).Count
    $top = Get-Process -ErrorAction SilentlyContinue | Sort-Object CPU -Descending | Select-Object -First 5 |
           ForEach-Object { "   $($_.ProcessName) (PID $($_.Id))" }
    $driveC = Get-PSDrive C -ErrorAction SilentlyContinue
    $freeGB = if ($driveC) { [math]::Round($driveC.Free / 1GB, 1) } else { "?" }
    Write-ActionLog "SYSTEM_STATUS" "local" "OK"
    return @"
🖥️ Статус системы:
ОС: $(if ($os) { $os.Caption } else { "Windows" })
Процессор: $(if ($cpu) { $cpu.Name.Trim() } else { "?" })
RAM: свободно $memFreeGB GB из $memTotalGB GB
Диск C: свободно $freeGB GB
Процессов: $procs
Топ-5 по CPU:
$($top -join "`n")
"@
}

function Get-RunningProcesses {
    $list = Get-Process -ErrorAction SilentlyContinue | Sort-Object CPU -Descending | Select-Object -First 15 |
            ForEach-Object { "   {0,-25} PID {1,-7} RAM {2} MB" -f $_.ProcessName, $_.Id, [math]::Round($_.WorkingSet64/1MB,0) }
    Write-ActionLog "LIST_PROCESSES" "local" "Показано топ-15"
    return "📋 Активные процессы (топ-15 по CPU):`n$($list -join "`n")"
}

# Разбор естественного языка: намерение + аргументы
function Parse-Intent {
    param([string]$Text)
    $t = $Text.Trim()
    $lower = $t.ToLower()

    $quoted = [regex]::Match($t, '["“”«»](.+?)["“”«»]').Groups[1].Value
    $fileArg = if ($quoted) { $quoted } else { [regex]::Match($lower, '(?:файл|папку|директор\w+|catalog|файла)?\s*[:\-]?\s*([\w\.\-\\/:%~\u0430-\u044f]+)').Groups[1].Value }

    # Программы и команды
    if ($lower -match "^(выполни|запусти команду|run|команда)\s*[:\-]?\s*(.+)") {
        return @{ intent = "run_command"; args = @{ command = $Matches[2].Trim() } }
    }
    if ($lower -match "^(открой|запусти|open|launch)\s+(не\s+)?(.+)") {
        $m = $Matches[3].Trim()
        if ($m -match "\.(exe|bat|cmd|msi|txt|pdf|docx?|xlsx?|html?|ps1)$" -or (Resolve-SafePath $m)) {
            return @{ intent = "file_open"; args = @{ path = $m } }
        }
        return @{ intent = "open_program"; args = @{ target = $m } }
    }

    # Диалог о коде с активным файлом ("измени", "покажи строку N")
    if ($lower -match "^(измени|исправь|замени|поправь|edit|fix)\b") {
        $mm = [regex]::Match($t, '(?i)замени\s+"?(.+?)"?\s+(на|=>|->)\s+"?(.+?)"?$')
        if ($mm.Success) {
            return @{ intent = "file_replace"; args = @{ path = $fileArg; find = $mm.Groups[1].Value; replace = $mm.Groups[3].Value } }
        }
        return @{ intent = "need_clarify_edit"; args = @{} }
    }

    # Файловые операции
    if ($lower -match "^(покажи список|список|ls|dir|что в|покажи папку|покажи файлы)") {
        return @{ intent = "file_list"; args = @{ path = $fileArg } }
    }
    if ($lower -match "^(прочитай|открой для чтения|покажи содержимое|покажи файл|читай|cat|read)\b") {
        return @{ intent = "file_read"; args = @{ path = $fileArg } }
    }
    if ($lower -match "^(создай файл|запиши|сохрани|create file|write|new file)\b") {
        $contentM = [regex]::Match($t, '(?i)(?:текст|содержимое|строку|строки)[:\-\s]*["“”](.*?)["“”]')
        $body = if ($contentM.Success) { $contentM.Groups[1].Value } else { "" }
        return @{ intent = "file_write"; args = @{ path = $fileArg; content = $body } }
    }
    if ($lower -match "^(добавь в файл|допиши|append)\b") {
        $contentM = [regex]::Match($t, '["“”](.*?)["“”]')
        return @{ intent = "file_append"; args = @{ path = $fileArg; content = $contentM.Groups[1].Value } }
    }
    if ($lower -match "^(удали|delete|remove|стер|убери)\b") {
        return @{ intent = "file_delete"; args = @{ path = $fileArg } }
    }
    if ($lower -match "^(создай папку|mkdir|новая папка)\b") {
        return @{ intent = "file_mkdir"; args = @{ path = $fileArg } }
    }
    if ($lower -match "^(перемести|move|mv)\b") {
        $mm = [regex]::Match($t, '(?i)["“”](.+?)["“”]\s*(?:в|to|->)\s*["“”](.+?)["“”]')
        return @{ intent = "file_move"; args = @{ path = $mm.Groups[1].Value; dest = $mm.Groups[2].Value } }
    }
    if ($lower -match "^(скопируй|копируй|copy|cp)\b") {
        $mm = [regex]::Match($t, '(?i)["“”](.+?)["“”]\s*(?:в|to|->)\s*["“”](.+?)["“”]')
        return @{ intent = "file_copy"; args = @{ path = $mm.Groups[1].Value; dest = $mm.Groups[2].Value } }
    }
    if ($lower -match "^(найди|ищи|search|find|где файл)\b") {
        $mm = [regex]::Match($t, '["“”](.+?)["“”]')
        $pat = if ($mm.Success) { $mm.Groups[1].Value } else { ($t -replace '^[\wа-яА-Я]+\s+', '') }
        return @{ intent = "file_search"; args = @{ pattern = $pat; path = $fileArg } }
    }
    if ($lower -match "^(информация о файле|свойства файла|размер файла|о файле)\b") {
        return @{ intent = "file_info"; args = @{ path = $fileArg } }
    }
    if ($lower -match "^(отмени|верни|undo|откат)\b") {
        return @{ intent = "undo"; args = @{} }
    }

    # Система
    if ($lower -match "(состояние|статус) (системы|пк|компьютера)|сколько (памяти|рам|оперативки)|производительность") {
        return @{ intent = "system_status"; args = @{} }
    }
    if ($lower -match "процессы|что запущено|открытые программы|список программ|что работает") {
        return @{ intent = "list_processes"; args = @{} }
    }

    return @{ intent = $null; args = @{} }
}

function Execute-Intent {
    param([hashtable]$Parsed, [string]$UserText)
    $intent = $Parsed.intent
    $args2 = $Parsed.args
    switch ($intent) {
        "run_command"     { return @(@{ response = Invoke-SystemCommand $args2.command }, $intent) }
        "open_program"    { return @(@{ response = Open-ProgramOrFile $args2.target }, $intent) }
        "file_open"       { return @(@{ response = Invoke-FileOperation (@{action="read"} + $args2) }, $intent) }
        "file_list"       { return @(@{ response = Invoke-FileOperation (@{action="list"} + $args2) }, $intent) }
        "file_read"       { return @(@{ response = Invoke-FileOperation (@{action="read"} + $args2) }, $intent) }
        "file_write"      {
            if (-not $args2.content) {
                return @(@{ response = "ℹ️ Укажите текст в кавычках, например: `nсоздай файл `"test.txt`" текст: `"Привет!`"" }, $intent)
            }
            return @(@{ response = Invoke-FileOperation (@{action="write"} + $args2) }, $intent)
        }
        "file_append"     { return @(@{ response = Invoke-FileOperation (@{action="append"} + $args2) }, $intent) }
        "file_replace"    {
            if (-not $args2.path -and $script:context.lastFile) { $args2.path = $script:context.lastFile }
            if (-not $args2.path) { return @(@{ response = "ℹ️ Сначала откройте файл (например: покажи файл example.txt), затем: замени `"старое`" на `"новое`"" }, $intent) }
            return @(@{ response = Invoke-FileOperation (@{action="replace"} + $args2) }, $intent)
        }
        "file_delete"     { return @(@{ response = Invoke-FileOperation (@{action="delete"} + $args2) }, $intent) }
        "file_mkdir"      { return @(@{ response = Invoke-FileOperation (@{action="mkdir"} + $args2) }, $intent) }
        "file_move"       { return @(@{ response = Invoke-FileOperation (@{action="move"} + $args2) }, $intent) }
        "file_copy"       { return @(@{ response = Invoke-FileOperation (@{action="copy"} + $args2) }, $intent) }
        "file_search"     { return @(@{ response = Invoke-FileOperation (@{action="search"} + $args2) }, $intent) }
        "file_info"       { return @(@{ response = Invoke-FileOperation (@{action="info"} + $args2) }, $intent) }
        "undo"            { return @(@{ response = Undo-LastChange }, $intent) }
        "system_status"   { return @(@{ response = Get-SystemStatus }, $intent) }
        "list_processes"  { return @(@{ response = Get-RunningProcesses }, $intent) }
        "need_clarify_edit" {
            $hint = if ($script:context.lastFile) { "Активный файл: $(Split-Path $script:context.lastFile -Leaf). Скажите точнее, например: замени `"foo`" на `"bar`"" } else { "Сначала откройте файл: покажи файл имя.txt" }
            return @(@{ response = "✏️ $hint" }, $intent)
        }
    }
    return $null
}

function Get-AIResponse {
    param(
        [string]$UserText,
        [hashtable]$Context
    )
    
    $lower = $UserText.ToLower()

    # Сначала пробуем распознать действие (файлы/программы/система)
    $parsed = Parse-Intent -Text $UserText
    if ($parsed.intent) {
        $execResult = Execute-Intent -Parsed $parsed -UserText $UserText
        if ($execResult) {
            return @{ response = $execResult[0].response; intent = $parsed.intent }
        }
    }

    # Приветствия
    if ($lower -match "^(привет|здравствуй|хай|hello)\b") {
        $hour = (Get-Date).Hour
        $greeting = if ($hour -lt 12) { "Доброе утро" } elseif ($hour -lt 18) { "Добрый день" } else { "Добрый вечер" }
        return @{ response = "$greeting! Я J — ваш AI-ассистент. Умею работать с файлами, папками, программами и командами на вашем ПК, а также поддерживать беседу. Например: `n• покажи список файлов`n• создай файл `"test.txt`" текст: `"Привет!`"`n• выполни ipconfig`n• запусти notepad`n• статус системы"; intent = "greeting" }
    }
    
    # Время
    if ($lower -match "который час|время|дата|сегодня") {
        $now = Get-Date
        return @{ response = "📅 $($now.ToString('dd.MM.yyyy'))`n⏰ $($now.ToString('HH:mm:ss'))"; intent = "time" }
    }
    
    # Благодарность
    if ($lower -match "^(спасибо|благодар|отлично|супер)\b") {
        return @{ response = "Всегда рад помочь! 😊"; intent = "thanks" }
    }
    
    # Прощание
    if ($lower -match "^(пока|до свидания|бай)\b") {
        return @{ response = "До встречи! 👋"; intent = "farewell" }
    }
    
    # Помощь по возможностям
    if ($lower -match "^(помощь|help|что ты умеешь|команды|возможности)\b") {
        return @{ response = @"
🛠️ Мои возможности (всё логируется в logs/):
📂 Файлы и папки:
  • покажи список файлов [папка]
  • покажи файл example.txt (чтение кода)
  • создай файл `"test.txt`" текст: `"Привет!`"
  • добавь в файл `"test.txt`" `"новая строка`"
  • замени `"старое`" на `"новое`" (в активном файле)
  • удали файл `"test.txt`" | создай папку `"new`"
  • перемести/скопируй `"a.txt`" в `"b.txt`"
  • найди `"report`" | отмени (последнее изменение)
🖥️ Программы и команды:
  • выполни ipconfig /all
  • запусти notepad | открой calc.exe
📊 Система:
  • статус системы | какие процессы запущены
💬 Диалог: база знаний (python, javascript, ai, ml, нейросети), время, приветствия.
"@; intent = "help" }
    }

    # Поиск в базе знаний
    foreach ($key in $script:knowledgeBase.Keys) {
        $entry = $script:knowledgeBase[$key]
        foreach ($keyword in $entry.keywords) {
            if ($lower -match $keyword) {
                # Обновляем контекст
                $script:context.lastTopic = $script:context.topic
                $script:context.topic = $key
                return @{ response = $entry.text; intent = "kb:$key" }
            }
        }
    }

    # Активный диалог: если был предыдущий контекст — поддерживаем беседу с учётом истории
    $historyHint = ""
    if ($script:conversationHistory.Count -ge 2) {
        $lastAssistant = ($script:conversationHistory | Where-Object { $_.role -eq "assistant" } | Select-Object -Last 1)
        if ($lastAssistant -and $UserText.Length -lt 40) {
            $historyHint = "`n💡 Продолжаем беседу (реплик в диалоге: $($script:conversationHistory.Count)). Уточните запрос или напишите «помощь» для списка команд."
        }
    }

    # Дефолтный ответ
    return @{ response = "Я вас понял. Я умею работать с файлами, папками, программами и командами на ПК, а также поддерживать беседу (python, AI, ML, нейросети). Напишите «помощь», чтобы увидеть все команды.$historyHint"; intent = "default" }
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

    # Логируем реплику пользователя в полный лог диалога
    Write-DialogLog -Role "user" -Content $UserInput

    # Обработка через AI (диалог + действия с ПК)
    $aiResult = Get-AIResponse -UserText $UserInput -Context $script:context
    $response = $aiResult.response

    # Добавляем ответ в историю
    $script:conversationHistory += @{
        role = "assistant"
        content = $response
        intent = $aiResult.intent
        timestamp = Get-Date
    }

    # Логируем ответ ассистента с распознанным намерением
    Write-DialogLog -Role "assistant" -Content $response -Intent $aiResult.intent
    
    Write-ServerLog "Отправлен ответ ($($aiResult.intent)): $($response.Substring(0, [Math]::Min(50, $response.Length)))..."
    
    return @{
        response = $response
        intent = $aiResult.intent
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
                    intent = $result.intent
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
Write-Host "   Версия 3.0" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Start-Server
