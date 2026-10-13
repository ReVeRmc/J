# ============================================
# J AI ASSISTANT - СЕРВЕРНАЯ ЧАСТЬ (v5.0)
# PowerShell сервер с AI логикой: навыки топовых открытых ИИ-систем
# AutoGPT / BabyAGI (автономные агенты), Open Interpreter (код+shell),
# Aider (рефакторинг кода), SWE-agent (поиск по кодовой базе),
# Stenography / ShellGPT (терминал), AgentGPT (планирование задач),
# TaskWeaver (workflow), Whisper-подобные заметки, MemGPT (память), ScreenPipe (скриншоты)
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
    lastCodeLang = $null  # язык последнего выполненного кода
    agentGoal = $null     # активная автономная задача (AutoGPT-стиль)
}

# Память ассистента (MemGPT-подобная): долговременные факты между сессиями
$script:memoryFile = $null   # инициализируется после ScriptDir

# Очередь задач автономного агента (BabyAGI/AgentGPT-стиль)
$script:taskQueue = @()      # @{ id; goal; status; steps; result }
$script:taskIdCounter = 0

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

# Ограничений по путям нет: ассистент работает со всей файловой системой.
# Для безопасности на уровне ОС запускайте сервер от имени администратора
# (PowerShell «Запуск от имени администратора») — тогда доступны системные папки.

function Resolve-SafePath {
    # Разворачивает относительный путь в полный (любая локация в системе)
    param([string]$RawPath)
    if ([string]::IsNullOrWhiteSpace($RawPath)) { return $null }
    $candidate = if ([System.IO.Path]::IsPathRooted($RawPath)) { $RawPath } else { Join-Path (Get-Location).Path $RawPath }
    try { return [System.IO.Path]::GetFullPath($candidate) } catch { return $null }
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
    if (-not $path) { return "⛔ Не удалось разобрать путь (проверьте корректность пути)." }
    # Если относительное имя не найдено в текущей папке, но такой файл является активным — используем его полный путь
    if (-not (Test-Path $path) -and -not [System.IO.Path]::IsPathRooted($Op.path) -and $script:context.lastFile) {
        $lfName = Split-Path $script:context.lastFile -Leaf
        if ($lfName -eq (Split-Path $path -Leaf)) { $path = $script:context.lastFile }
    }

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

# Запуск программ и команд (без ограничений — полный доступ к системе)
function Invoke-SystemCommand {
    param([string]$CommandLine)
    $script:context.lastCommand = $CommandLine
    Write-ServerLog "Выполняю команду: $CommandLine" "WARNING"
    try {
        if ($IsMacOS -or $IsLinux) {
            $output = & /bin/sh -c $CommandLine 2>&1 | Out-String
        } else {
            $output = & cmd.exe /c $CommandLine 2>&1 | Out-String
        }
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
    # Кроссплатформенно: Windows / macOS / Linux (Android через Termux + PowerShell)
    $platform = if ($IsWindows) { "Windows" } elseif ($IsMacOS) { "macOS" } elseif ($IsLinux) { "Linux" } else { "Windows" }
    $osName = "$platform $(if ($PSVersionTable) { "(PowerShell $($PSVersionTable.PSVersion))" })"
    $cpuInfo = try { [Environment]::ProcessorCount } catch { "?" }
    $procs = (Get-Process -ErrorAction SilentlyContinue).Count
    $top = Get-Process -ErrorAction SilentlyContinue | Sort-Object CPU -Descending | Select-Object -First 5 |
           ForEach-Object { "   $($_.ProcessName) (PID $($_.Id))" }
    # Диск: C: на Windows, корень на Unix-системах
    $drivePath = if ($IsWindows -or -not $PSVersionTable.ContainsKey("Platform")) { "C" } else { "/" }
    $drive = Get-PSDrive $drivePath -ErrorAction SilentlyContinue
    $freeGB = if ($drive -and $null -ne $drive.Free) { [math]::Round($drive.Free / 1GB, 1) } else { "?" }
    $totalGB = if ($drive -and $null -ne $drive.Used -and $null -ne $drive.Free) { [math]::Round(($drive.Used + $drive.Free) / 1GB, 1) } else { "?" }
    Write-ActionLog "SYSTEM_STATUS" $platform "OK"
    return @"
🖥️ Статус системы:
ОС: $osName
Ядро: $([System.Environment]::OSVersion.VersionString)
CPU ядер: $cpuInfo
Диск '$drivePath': свободно $freeGB GB из $totalGB GB
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

# ============================================
# МОДУЛЬ 4.0: НАВЫКИ ОТКРЫТЫХ ИИ-СИСТЕМ
# ============================================

# ---------- ПАМЯТЬ (MemGPT-style) ----------
$script:memoryFile = Join-Path $ScriptDir "logs\memory.json"
$script:memories = @()
if (Test-Path $script:memoryFile) {
    try { $script:memories = @(Get-Content $script:memoryFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $script:memories = @() }
}

function Save-Memory {
    try { $script:memories | ConvertTo-Json -Depth 5 | Set-Content -Path $script:memoryFile -Encoding UTF8 } catch { }
}

function Add-MemoryFact {
    param([string]$Fact)
    $script:memories += @{ time = (Get-Date -Format "o"); fact = $Fact }
    if ($script:memories.Count -gt 500) { $script:memories = $script:memories[-500..-1] }
    Save-Memory
    Write-ActionLog "MEMORY_ADD" "-" "Запомнено: $Fact"
    return "🧠 Запомнил: «$Fact» (всего фактов: $($script:memories.Count))"
}

function Recall-Memories {
    param([string]$Query = "")
    if (-not $script:memories -or $script:memories.Count -eq 0) { return "🧠 Память пуста. Скажите: запомни ..." }
    $items = $script:memories
    if ($Query) {
        $items = @($script:memories | Where-Object { $_.fact -like "*$Query*" })
        if ($items.Count -eq 0) { return "🧠 По запросу «$Query» ничего не найдено." }
    }
    $lines = $items | Select-Object -Last 20 | ForEach-Object { "• [$($_.time.Substring(0,10))] $($_.fact)" }
    Write-ActionLog "MEMORY_RECALL" $Query "Найдено: $($items.Count)"
    return "🧠 Память ($($items.Count) записей):`n$($lines -join "`n")"
}

function Forget-Memory {
    param([string]$Query)
    $before = $script:memories.Count
    $script:memories = @($script:memories | Where-Object { $_.fact -notlike "*$Query*" })
    Save-Memory
    $removed = $before - $script:memories.Count
    Write-ActionLog "MEMORY_FORGET" $Query "Удалено: $removed"
    return $(if ($removed -gt 0) { "🗑️ Забыто записей: $removed" } else { "ℹ️ Ничего не найдено для удаления: «$Query»" })
}

# ---------- ВЫПОЛНЕНИЕ КОДА (Open Interpreter-style) ----------
function Invoke-AIInterpreterCode {
    param([string]$Code, [string]$LangHint = "")
    # Автоопределение языка
    $lang = $LangHint.ToLower()
    if (-not $lang) {
        if     ($Code -match "^\s*(def |import |print\(|from |class )") { $lang = "python" }
        elseif ($Code -match "^\s*(const |let |var |function |console\.log|=>)") { $lang = "javascript" }
        elseif ($Code -match "^\s*(Write-Host|Get-|Set-|\$\w+\s*=)") { $lang = "powershell" }
        elseif ($Code -match "^\s*(echo |ls |cd |grep |curl |cat )") { $lang = "shell" }
        else { $lang = "auto" }
    }
    $codeFile = Join-Path ([System.IO.Path]::GetTempPath()) ("j_ai_code_" + (Get-Random) + $(switch ($lang) { "python" {".py"} "javascript" {".js"} "powershell" {".ps1"} default {".sh"} }))
    $script:context.lastCodeLang = $lang
    try {
        Set-Content -Path $codeFile -Value $Code -Encoding UTF8
        switch ($lang) {
            "python"     { $out = (& python $codeFile 2>&1 | Out-String); $rt = "Python" }
            "javascript" { $out = (& node $codeFile 2>&1 | Out-String); $rt = "Node.js" }
            "powershell" { $out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $codeFile 2>&1 | Out-String); $rt = "PowerShell" }
            "shell"      { $out = (& /bin/sh $codeFile 2>&1 | Out-String); $rt = "Shell" }
            "auto"       {
                # пробуем по очереди: python -> node -> shell/powershell
                $py = Get-Command python -ErrorAction SilentlyContinue
                $nd = Get-Command node -ErrorAction SilentlyContinue
                if ($py) { $out = (& python $codeFile 2>&1 | Out-String); $rt = "Python (auto)" }
                elseif ($nd) { $out = (& node $codeFile 2>&1 | Out-String); $rt = "Node.js (auto)" }
                elseif ($IsWindows -or -not $PSVersionTable.ContainsKey("Platform")) { $out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $codeFile 2>&1 | Out-String); $rt = "PowerShell (auto)" }
                else { $out = (& /bin/sh $codeFile 2>&1 | Out-String); $rt = "Shell (auto)" }
            }
            default { Remove-Item $codeFile -Force -ErrorAction SilentlyContinue; return "❌ Неизвестный язык: $lang (доступно: python, javascript/node, powershell, shell)" }
        }
        Remove-Item $codeFile -Force -ErrorAction SilentlyContinue
        $trimmed = if ($out.Length -gt 4000) { $out.Substring(0,4000) + "`n...[обрезано]" } else { $out }
        if ([string]::IsNullOrWhiteSpace($trimmed)) { $trimmed = "(код выполнен без вывода)" }
        Write-ActionLog "RUN_CODE" "$rt ($(if($Code.Length -gt 60){$Code.Substring(0,60)+"..."}else{$Code}))" "OK"
        return "🧮 Код выполнен ($rt):`n------`n$trimmed"
    } catch {
        Remove-Item $codeFile -Force -ErrorAction SilentlyContinue
        Write-ActionLog "RUN_CODE_FAIL" $lang $_.Exception.Message
        return "❌ Ошибка выполнения кода: $($_.Exception.Message)"
    }
}

# ---------- GIT-НАВЫКИ (Aider/OpenHands-style) ----------
function Invoke-GitOperation {
    param([string]$GitArgs, [string]$RepoDir = "")
    $dir = if ($RepoDir) { Resolve-SafePath $RepoDir } else { (Get-Location).Path }
    if (-not $dir -or -not (Test-Path $dir)) { return "❌ Папка репозитория не найдена: $dir" }
    try {
        # GitArgs уже начинается с подкоманды (status/log/commit...); iex раскрывает кавычки вида -m "msg"
        $cmd = ('git -C "' + $dir.Replace('"','') + '" ' + $GitArgs)
        if ($cmd -notmatch '^git -C "[^"]*" (status|log|commit|add|push|pull|clone|branch|diff|init|checkout|merge|tag)\b') { return "⛔ Разрешены только стандартные git-подкоманды." }
        $out = Invoke-Expression "$cmd 2>&1" | Out-String
        $rc = if ($LASTEXITCODE -ne $null) { $LASTEXITCODE } else { 0 }
        $trimmed = if ($out.Length -gt 3000) { $out.Substring(0,3000) + "..." } else { $out }
        if ([string]::IsNullOrWhiteSpace($trimmed)) { $trimmed = "(без вывода)" }
        Write-ActionLog "GIT" "git $GitArgs @ $dir" "Код: $rc"
        return "🌿 git $GitArgs ($dir)`nКод возврата: $rc`n------`n$trimmed"
    } catch {
        Write-ActionLog "GIT_FAIL" "git $GitArgs" $_.Exception.Message
        return "❌ Git ошибка: $($_.Exception.Message)`n(убедитесь, что git установлен: выполни git --version)"
    }
}

# ---------- РЕФАКТОРИНГ И АНАЛИЗ КОДА (Aider/SWE-agent-style) ----------
function Get-CodeSummary {
    param([string]$Path)
    $p = Resolve-SafePath $Path
    if (-not $p -or -not (Test-Path $p -PathType Leaf)) { return "❌ Файл не найден: $p (сначала: покажи файл путь)" }
    $content = Get-Content $p -Raw -Encoding UTF8
    $fi = Get-Item $p
    $lines = ($content -split "`n").Count
    $ext = $fi.Extension.ToLower()
    $stats = @{ File = $fi.Name; Path = $p; Lines = $lines; SizeKB = [math]::Round($fi.Length/1KB,2); Ext = $ext }
    $funcs = @()
    switch ($ext) {
        { $_ -in ".py",".js",".ts",".ps1",".sh",".rb",".go",".php",".c",".cpp",".java",".cs" } {
            $funcs = @([regex]::Matches($content, '(?m)^\s*(?:def|function|func)\s+([\w]+)|^\s*([\w]+)\s*\([^)]*\)\s*\{|(?:public|private|static|void|class)\s+(?:[\w<>\[\]]+\s+)?([\w]+)\s*[\(\{]') |
                ForEach-Object { ($_.Groups | Where-Object { $_.Success -and $_.Name -ne "0" }).Value } | Where-Object { $_ } | Select-Object -Unique)
        }
    }
    $imports = @([regex]::Matches($content, '(?m)^\s*(?:import|from|require|#include|use)\s+[\w\.\{\}"'' ,<>]+') | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique -First 20)
    $classes = @([regex]::Matches($content, '(?m)^\s*(?:class|interface|struct|enum)\s+([\w]+)') | ForEach-Object { $_.Groups[1].Value })
    $todos   = @([regex]::Matches($content, '(TODO|FIXME|XXX|HACK)[:\s]*([^\r\n]*)') | ForEach-Object { $_.Value.Trim() } | Select-Object -First 10)
    $commentLines = @($content -split "`n" | Where-Object { $_ -match '^\s*(//|#|/\*|\*|--)' }).Count
    $codePart = "📊 Анализ файла: $($stats.File)`nСтрок: $lines | Размер: $($stats.SizeKB) KB | Комментариев: $commentLines строк"
    if ($classes.Count) { $codePart += "`n🏛️ Классы/структуры ($($classes.Count)): " + ($classes -join ", ") }
    if ($funcs.Count)   { $codePart += "`n⚙️ Функции ($($funcs.Count)): " + (($funcs | Select-Object -First 30) -join ", ") }
    if ($imports.Count) { $codePart += "`n📦 Импорт/зависимости: " + ($imports -join "; ") }
    if ($todos.Count)   { $codePart += "`n📌 TODO/FIXME:`n" + ($todos -join "`n") }
    $script:context.lastFile = $p
    Write-ActionLog "CODE_ANALYZE" $p "Строк: $lines, функций: $($funcs.Count), классов: $($classes.Count)"
    return $codePart
}

function Find-InCodebase {
    # SWE-agent style: текстовый поиск по содержимому файлов (аналог grep/ripgrep)
    param([string]$Pattern, [string]$Root = "", [string]$ExtFilter = "")
    $rootPath = if ($Root) { Resolve-SafePath $Root } else { (Get-Location).Path }
    if (-not (Test-Path $rootPath)) { return "❌ Папка не найдена: $rootPath" }
    $files = Get-ChildItem -Path $rootPath -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Length -lt 1MB -and $_.FullName -notmatch '\\(node_modules|\.git|venv|__pycache__|bin|obj|dist|build)\\' }
    if ($ExtFilter) { $files = $files | Where-Object { $_.Extension -like "*$ExtFilter*" } }
    $hits = @()
    foreach ($f in $files) {
        try {
            $ln = 0
            foreach ($line in (Get-Content $f.FullName -ErrorAction Stop)) {
                $ln++
                if ($line -like "*$Pattern*") {
                    $hits += "   $($f.FullName):$ln  $($line.Trim().Substring(0, [Math]::Min(90, $line.Trim().Length)))"
                    if ($hits.Count -ge 40) { break }
                }
            }
        } catch { }
        if ($hits.Count -ge 40) { break }
    }
    Write-ActionLog "GREP_CODEBASE" "$Pattern @ $rootPath" "Совпадений: $($hits.Count)"
    if ($hits.Count -eq 0) { return "🔍 Совпадений не найдено: «$Pattern» (просканировано файлов: $($files.Count))" }
    return "🔍 Grep «$Pattern» — $($hits.Count) совпадений:`n" + ($hits -join "`n")
}

# ---------- АВТОНОМНЫЙ АГЕНТ (AutoGPT/BabyAGI/AgentGPT-style) ----------
function Start-AgentTask {
    param([string]$Goal)
    $script:taskIdCounter++
    $task = @{
        id = $script:taskIdCounter
        goal = $Goal
        status = "running"
        steps = @()
        result = $null
        created = (Get-Date -Format "o")
    }
    $script:context.agentGoal = $Goal
    # Планирование шагов (эвристики по ключевым словам цели)
    $steps = @()
    $g = $Goal.ToLower()
    $steps += "1. Проанализировать цель: «$Goal»"
    if ($g -match "файл|папку|директор|создать|create") { $steps += "2. Подготовить файловую структуру (mkdir/create file)" ; $steps += "3. Записать содержимое и проверить результат (file_read/list)" }
    if ($g -match "установ|install|pip|npm|apt")        { $steps += "2. Выполнить установку: выполни <пакетный менеджер + пакет>" ; $steps += "3. Проверить установку командой версии" }
    if ($g -match "сайт|html|web|страниц")              { $steps += "2. Создать index.html/css/js (создай файл ...)" ; $steps += "3. Открыть в браузере: открой index.html" }
    if ($g -match "скрипт|автоматиз|bot|бот")           { $steps += "2. Написать скрипт (exec code python/ps1)" ; $steps += "3. Протестировать запуск и исправить ошибки" }
    if ($g -match "резерв|backup|копир")                { $steps += "2. Скопировать данные (скопируй ...)" ; $steps += "3. Проверить целостность копии (info)" }
    $steps += "$($steps.Count + 1). Составить итоговый отчёт"
    $task.steps = $steps
    $script:taskQueue += $task
    Write-ActionLog "AGENT_START" "task#$($task.id)" "Цель: $Goal"
    $planText = ($steps | ForEach-Object { "  $_" }) -join "`n"
    return "🤖 Автономная задача #$($task.id) запущена (AutoGPT/BabyAGI-стиль)`nЦель: $Goal`nПлан:`n$planText`n------`nВыполняйте шаги командами ассистента или скажите «выполни задачу» для автоматической попытки.`n«статус задач» — прогресс, «отчёт задач» — итоги, «отмени задачу» — остановить."
}

function Complete-AgentStep {
    $active = $script:taskQueue | Where-Object { $_.status -eq "running" } | Select-Object -Last 1
    if (-not $active) { return "ℹ️ Нет активной задачи. Скажите: выполни задачу <цель>" }
    # Авто-шаг: если цель содержит явное действие — выполняем его
    $g = $active.goal.ToLower()
    $done = $null
    if ($g -match "создай папку\s*[«""']?([\w\.\-\\/ ]+)[»""']?") { $done = Invoke-FileOperation @{ action="mkdir"; path=$Matches[1].Trim() } }
    elseif ($g -match "установи (\S+)") { $pkg=$Matches[1]; $done = Invoke-SystemCommand "pip install $pkg 2>&1 || npm install -g $pkg 2>&1" }
    if ($done) {
        $active.steps_done = @($active.steps_done) + $done
        Write-ActionLog "AGENT_STEP" "task#$($active.id)" $done
        return "🤖 Шаг задачи #$($active.id) авто-выполнен:`n$done"
    }
    $active.status = "done"
    $active.result = "Отмечено ручное завершение последнего шага"
    Write-ActionLog "AGENT_DONE" "task#$($active.id)" "Завершена"
    return "✅ Задача #$($active.id) «$($active.goal)» помечена завершённой. «отчёт задач» покажет итоги."
}

function Get-AgentStatus {
    if ($script:taskQueue.Count -eq 0) { return "ℹ️ Задач нет. Скажите: выполни задачу <цель>" }
    $lines = $script:taskQueue | Select-Object -Last 10 | ForEach-Object {
        $icon = switch ($_.status) { "running" {"🔄"} "done" {"✅"} "cancelled" {"⛔"} default {"•"} }
        "  $icon #$($_.id) [$($_.status)] $($_.goal)"
    }
    return "🤖 Статус автономных задач:`n" + ($lines -join "`n")
}

function Get-AgentReport {
    if ($script:taskQueue.Count -eq 0) { return "ℹ️ Задач не было." }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("📑 Отчёт по задачам (всего: $($script:taskQueue.Count)):")
    foreach ($t in $script:taskQueue) {
        [void]$sb.AppendLine("---")
        [void]$sb.AppendLine("#$($t.id) [$($t.status)] $($t.goal)  (создана: $($t.created.Substring(0,19)))")
        [void]$sb.AppendLine("План:")
        foreach ($s in $t.steps) { [void]$sb.AppendLine("  $s") }
        if ($t.steps_done) { [void]$sb.AppendLine("Авто-выполненные шаги:"); foreach ($d in $t.steps_done) { [void]$sb.AppendLine("  > $d") } }
    }
    Write-ActionLog "AGENT_REPORT" "-" "Задач: $($script:taskQueue.Count)"
    return $sb.ToString()
}

function Cancel-AgentTask {
    $active = $script:taskQueue | Where-Object { $_.status -eq "running" } | Select-Object -Last 1
    if (-not $active) { return "ℹ️ Нет активных задач." }
    $active.status = "cancelled"
    $script:context.agentGoal = $null
    Write-ActionLog "AGENT_CANCEL" "task#$($active.id)" "Остановлена"
    return "⛔ Задача #$($active.id) остановлена."
}

# ---------- Мультимедиа: скриншоты, буфер обмена, заметки (ScreenPipe/Whisper-style) ----------
function Take-Screenshot {
    $file = Join-Path $ScriptDir ("logs\screenshot_{0}.png" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    try {
        if ($IsWindows -or -not $PSVersionTable.ContainsKey("Platform")) {
            Add-Type -AssemblyName System.Windows.Forms, System.Drawing
            $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
            $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
            $gfx = [System.Drawing.Graphics]::FromImage($bmp)
            $gfx.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
            $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
            $gfx.Dispose(); $bmp.Dispose()
        } else {
            # macOS/Linux/Termux
            if (Get-Command screencapture -ErrorAction SilentlyContinue) { & screencapture -x $file }
            elseif (Get-Command import -ErrorAction SilentlyContinue)     { & import -window root $file }
            elseif (Get-Command termux-open -ErrorAction SilentlyContinue) { return "ℹ️ Termux: используйте команду termux-screenshot (плагин termux-api)." }
            else { return "❌ Утилита для скриншота не найдена (screencapture/import)." }
        }
        Write-ActionLog "SCREENSHOT" $file "Сохранён"
        return "📸 Скриншот сохранён: $file"
    } catch {
        Write-ActionLog "SCREENSHOT_FAIL" "-" $_.Exception.Message
        return "❌ Ошибка скриншота: $($_.Exception.Message)"
    }
}

function Get-ClipboardText {
    try {
        if ($IsWindows -or -not $PSVersionTable.ContainsKey("Platform")) {
            $text = Get-Clipboard -ErrorAction Stop
        } else {
            if (Get-Command xclip -ErrorAction SilentlyContinue) { $text = & xclip -selection clipboard -o 2>&1 | Out-String }
            elseif (Get-Command pbpaste -ErrorAction SilentlyContinue) { $text = & pbpaste 2>&1 | Out-String }
            elseif (Get-Command termux-clipboard-get -ErrorAction SilentlyContinue) { $text = & termux-clipboard-get 2>&1 | Out-String }
            else { return "❌ Буфер обмена недоступен на этой системе." }
        }
        if ([string]::IsNullOrWhiteSpace($text)) { return "📋 Буфер обмена пуст." }
        $trimmed = if ($text.Length -gt 2000) { $text.Substring(0,2000) + "...[обрезано]" } else { $text }
        Write-ActionLog "CLIPBOARD_READ" "-" "$($text.Length) симв."
        return "📋 Буфер обмена:`n$trimmed"
    } catch { return "❌ Ошибка чтения буфера: $($_.Exception.Message)" }
}

function Set-ClipboardText {
    param([string]$Text)
    try {
        if ($IsWindows -or -not $PSVersionTable.ContainsKey("Platform")) { Set-Clipboard -Value $Text }
        elseif (Get-Command xclip -ErrorAction SilentlyContinue) { $Text | & xclip -selection clipboard }
        elseif (Get-Command pbcopy -ErrorAction SilentlyContinue) { $Text | & pbcopy }
        elseif (Get-Command termux-clipboard-set -ErrorAction SilentlyContinue) { $Text | & termux-clipboard-set }
        else { return "❌ Запись в буфер недоступна." }
        Write-ActionLog "CLIPBOARD_WRITE" "-" "$($Text.Length) симв."
        return "📋 Скопировано в буфер обмена: $($Text.Substring(0, [Math]::Min(80, $Text.Length)))"
    } catch { return "❌ Ошибка записи в буфер: $($_.Exception.Message)" }
}

function Add-VoiceNote {
    # Whisper-style заметки: голос через termux-media-player/rec, иначе — текстовая заметка с меткой времени
    param([string]$Text)
    $note = "[{0}] {1}" -f (Get-Date -Format "dd.MM.yyyy HH:mm"), $Text
    $noteFile = Join-Path $ScriptDir (Join-Path "logs" "notes.txt")
    Add-Content -Path $noteFile -Value $note -Encoding UTF8
    Write-ActionLog "NOTE_ADD" $noteFile $Text
    return "📝 Заметка сохранена ($noteFile):`n$note"
}

function Show-Notes {
    $noteFile = Join-Path $ScriptDir (Join-Path "logs" "notes.txt")
    if (-not (Test-Path $noteFile)) { return "📝 Заметок пока нет. Скажите: заметка <текст>" }
    $last = Get-Content $noteFile -Encoding UTF8 | Select-Object -Last 15
    return "📝 Последние заметки:`n" + ($last -join "`n")
}

# ---------- ПЕРЕВОДЧИК ЕСТЕСТВЕННЫХ ЯЗЫКОВ В КОМАНДЫ (Stenography/ShellGPT-style) ----------
function Translate-NlToCommands {
    param([string]$Text)
    $map = @{
        "найди все файлы pdf"        = 'выполни cmd: dir /s /b *.pdf (Windows) или find . -name "*.pdf"'
        "сколько занимает диск"      = 'выполни du -sh * (Linux/macOS) или dir C:\ (Windows)'
        "очисти временные файлы"     = 'выполни PowerShell: Remove-Item $env:TEMP\* -Recurse -Force'
        "покажи большой лог"         = 'выполни tail -n 100 logfile.txt'
        "убей зависшую программу"    = 'выполни taskkill /IM name.exe /F (Windows) или pkill name'
        "сделай архив папки"         = 'выполни tar -czf backup.tar.gz folder/ (или Compress-Archive folder backup.zip)'
        "скачай файл"                = 'выполни curl -L -o output.txt https://example.com/file'
        "проверь интернет"           = 'выполни ping -n 4 8.8.8.8'
        "покажи открытые порты"      = 'выполни netstat -ano | findstr LISTENING'
    }
    $lower = $Text.ToLower()
    $hints = @()
    foreach ($k in $map.Keys) { if ($lower -match ($k -replace " ",".*")) { $hints += $map[$k] } }
    if ($hints.Count -eq 0) {
        $hints = @(
            "💡 Универсальный рецепт: опишите действие проще («выполни <готовая команда>») или дайте код: exec python ..."
        )
    }
    Write-ActionLog "NL2CMD" $Text "Подсказок: $($hints.Count)"
    return "🗣➡️🖥 Перевод запроса в команды:`n" + ($hints -join "`n")
}

# ---------- WEB-НАВЫКИ (SearchGPT/AutoGPT Web-style) ----------
function Invoke-WebRequestSkill {
    param([string]$Url)
    if ($Url -notmatch "^https?://") { $Url = "https://$Url" }
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20
        $titleMatch = [regex]::Match($resp.Content, '<title[^>]*>(.*?)</title>', 'Singleline')
        $title = if ($titleMatch.Success) { $titleMatch.Groups[1].Value.Trim() } else { "(без заголовка)" }
        $text = ($resp.Content -replace '<script[\s\S]*?</script>|<style[\s\S]*?</style>|<[^>]+>', ' ' -replace '\s+', ' ')
        if ($text.Length -gt 2500) { $text = $text.Substring(0,2500) + "...[обрезано]" }
        Write-ActionLog "WEB_FETCH" $Url "HTTP $($resp.StatusCode), $($resp.RawContentLength) байт"
        return "🌐 $Url`nСтатус: HTTP $($resp.StatusCode) | Заголовок: $title`n------`n$text"
    } catch {
        Write-ActionLog "WEB_FETCH_FAIL" $Url $_.Exception.Message
        return "❌ Ошибка загрузки $Url : $($_.Exception.Message)"
    }
}

function Invoke-ApiCall {
    param([string]$Method, [string]$Url, [string]$Body = "")
    try {
        $params = @{ Uri = $Url; Method = $Method; UseBasicParsing = $true; TimeoutSec = 20 }
        if ($Body) { $params.Body = $Body; $params.ContentType = "application/json" }
        $resp = Invoke-WebRequest @params
        $content = $resp.Content
        if ($content.Length -gt 3000) { $content = $content.Substring(0,3000) + "...[обрезано]" }
        Write-ActionLog "API_CALL" "$Method $Url" "HTTP $($resp.StatusCode)"
        return "🔁 API $Method $Url → HTTP $($resp.StatusCode)`n------`n$content"
    } catch {
        Write-ActionLog "API_CALL_FAIL" "$Method $Url" $_.Exception.Message
        return "❌ Ошибка API: $($_.Exception.Message)"
    }
}

# ---------- ЗАЩИТА ОТ ПОТЕРЬ: бэкап перед опасной операцией ----------
function Backup-BeforeDanger {
    param([string]$Path)
    $p = Resolve-SafePath $Path
    if (-not $p -or -not (Test-Path $p)) { return $null }
    $bak = "$p.bak_$(Get-Date -Format yyyyMMdd_HHmmss)"
    try { Copy-Item $p $bak -Recurse -Force; Write-ActionLog "BACKUP" "$p -> $bak" "OK"; return $bak } catch { return $null }
}

# ---------- РАСШИРЕННАЯ СПРАВКА ----------
function Get-SuperHelp {
    return @"
🦾 J AI Assistant v4.0 — собран из лучших открытых ИИ-систем:

🕹 Автономные агенты (AutoGPT / BabyAGI / AgentGPT):
  • выполни задачу создай папку "project" и установи requests
  • статус задач | отчёт задач | заверши задачу | отмени задачу

🧮 Интерпретатор кода (Open Interpreter):
  • exec python print(sum(range(100)))
  • exec js fetch demo | exec ps1 Get-Date | exec bash ls -la

♻️ Рефакторинг и анализ кода (Aider / SWE-agent):
  • проанализируй файл main.py (функции, классы, импорты, TODO)
  • grep "login" в папке src (поиск по содержимому всей кодовой базы)
  • git status | git commit -m "msg" | git log (работа с репозиториями)

🧠 Память (MemGPT):
  • запомни мой проект лежит в D:\work\proj
  • вспомни проект | забудь D:\work

🌐 Интернет (AutoGPT-web / SearchGPT):
  • открой сайт example.com (чтение страницы)
  • api GET https://api.github.com/repos/power-shell/psreadline

📸 Мультимедиа и система (ScreenPipe / ShellGPT / TaskWeaver):
  • сделай скриншот | буфер обмена | скопируй в буфер "текст"
  • заметка встреча в 15:00 | покажи заметки
  • переведи в команды: найди все pdf файлы (NL→команды)
  • время | дата | статус системы | процессы

📚 База знаний (ответы из встроенной базы):
  • спроси квантовый компьютер простыми словами

📂 Плюс все файловые операции v3: список/чтение/создание/замена/удаление/перемещение/копирование/поиск/отмена.
⚠️ Все действия логируются в logs/. Опасные изменения автоматически резервируются (.bak_*).
"@
}

# Разбор естественного языка: намерение + аргументы
function Parse-Intent {
    param([string]$Text)
    $t = $Text.Trim()
    $lower = $t.ToLower()

    $quotedRaw = [regex]::Match($t, '["“”«»](.+?)["“”«»]').Groups[1].Value
    $quoted = if ($quotedRaw -and $quotedRaw -notmatch '\s') { $quotedRaw } else { "" }
    # Извлечение пути: кавычки → абсолютный путь (C:\, /, ~/, UNC) → после слова «файл/папку X»
    $pathM  = [regex]::Match($t, '(?i)((?:[A-Za-z]:[\\/]|\\\\|~[/\\]?|/)[^\s"<>|?*]+)')
    $relM   = [regex]::Match($lower, '(?:файла?|папк[уи]?|директори[ии]?|folder|dir|катало[гга])\s+(?:в\s+)?[:\-]?\s*([\w\.\-\\/%:~а-яё]+)')
    $fileArg = if ($quoted)           { $quoted }
               elseif ($pathM.Success) { $pathM.Groups[1].Value }
               elseif ($relM.Success)  { $relM.Groups[1].Value }
               else                   { "" }
    # Очистка хвостов служебных слов и пунктуации
    $fileArg = ($fileArg -replace '(?i)\s+(?:текст|содержимое|с текстом|информация|о файле|о папке|в|на|for|about)\s*$', '').TrimEnd(',', '.', ';', ':', ' ')
    $fileArg = ($fileArg -replace '(?i)^(в|на)\s+', '')

    # Программы и команды (кроме «выполни код/задачу» — их обрабатывают правила ниже)
    if ($lower -match "^(выполни|запусти команду|run|команда)\s*[:\-]?\s*(.+)" -and $lower -notmatch "^(выполни\s+(код|задачу)|run code)") {
        # Команда — всё, что после глагола (без обрезки по предлогам «в/на» и без подмены цитатами)
        $cmd = $Matches[2].Trim()
        return @{ intent = "run_command"; args = @{ command = $cmd } }
    }

    # === v4.0: НАВЫКИ ОТКРЫТЫХ ИИ-СИСТЕМ (проверяются раньше файловых) ===

    # Автономный агент (AutoGPT/BabyAGI/AgentGPT)
    if ($lower -match "^(выполни задачу|автономн\w+ задача|agent task|цель задачи)\s*[:\-]?\s*(.*)") {
        $goal = $Matches[2].Trim()
        if (-not $goal) { return @{ intent = "agent_start_empty"; args = @{} } }
        return @{ intent = "agent_start"; args = @{ goal = $goal } }
    }
    if ($lower -match "^(статус задач|задачи агента|agent status)") { return @{ intent = "agent_status"; args = @{} } }
    if ($lower -match "^(отчёт задач|отчет задач|agent report|итоги задач)") { return @{ intent = "agent_report"; args = @{} } }
    if ($lower -match "^(заверши задачу|шаг задачи|complete task|next step)") { return @{ intent = "agent_step"; args = @{} } }
    if ($lower -match "^(отмени задачу|останови задачу|stop agent)") { return @{ intent = "agent_cancel"; args = @{} } }

    # Интерпретатор кода (Open Interpreter)
    if ($lower -match "^(exec\s+код|exec|код[:\-\s]|выполни\s+код|run\s+code|interpreter)\s*(?:(python|py|js|javascript|node|nodejs|ps1|powershell|pwsh|bash|sh|shell)\b\s*)?[:\-]?\s*(.+)") {
        $langHint = ($Matches[2] -replace '^(nodejs)$','node').Trim(); $code = $Matches[3].Trim()
        # Кавычки — часть кода (console.log("hi")); подмена цитатой только если код целиком в кавычках
        $qm = [regex]::Match($t, '^.*["“«](.+?)["”»]\s*$')
        if ($qm.Success -and $code.Trim('"“»«') -eq $qm.Groups[1].Value) { $code = $qm.Groups[1].Value }
        return @{ intent = "exec_code"; args = @{ code = $code; lang = $langHint } }
    }

    # Git (Aider/OpenHands)
    if ($lower -match "^git\s+(status|log|commit|add|push|pull|clone|branch|diff|init|checkout|merge|tag)(.*)") {
        $repoM = [regex]::Match($t, '(?i)(?:в папке|репозиторий|repo)\s+["“”«]?([\w\.:\\/\-]+)')
        return @{ intent = "git_op"; args = @{ gitargs = ("$($Matches[1])$($Matches[2])").Trim(); repo = $repoM.Groups[1].Value } }
    }

    # Анализ кода (Aider/SWE-agent)
    if ($lower -match "^(проанализируй|разбери|изучи( файл)?|структура файла|анализ кода|анализ файла?|analyze)\b") {
        $mm = [regex]::Match($t, '(?i)(?:файл|код)\s*[:"“”«]?([\w\.\-\\/~:]+\.\w+)')
        $p = if ($mm.Success) { $mm.Groups[1].Value } elseif ($script:context.lastFile) { $script:context.lastFile } else { "" }
        return @{ intent = "code_analyze"; args = @{ path = $p } }
    }
    if ($lower -match "^(grep|поиск в коде|найти в файлах|search code|где используется)\b") {
        $mm = [regex]::Match($t, '["“”«](.+?)[\"“”»]')
        $pat = if ($mm.Success) { $mm.Groups[1].Value } else { ($t -replace '^[\wа-яА-Я]+\s+', '') }
        $rootM = [regex]::Match($t, '(?i)(?:в|в папке|в файлах)\s+["“”«]?([\w\.:\\/~\-]+\.\w+|[\w\.:\\/~\-]+)')
        return @{ intent = "grep_codebase"; args = @{ pattern = $pat; root = $rootM.Groups[1].Value } }
    }

    # Память (MemGPT)
    if ($lower -match "^(запомни|запиши в память|remember)\s*[:\-]?\s*(.+)") {
        return @{ intent = "memory_add"; args = @{ fact = $Matches[2].Trim() } }
    }
    if ($lower -match "^(вспомни|что ты знаешь о|что ты помнишь|помнишь что|покажи память|recall|memory)\s*[:\-]?\s*(.*)") {
        return @{ intent = "memory_recall"; args = @{ query = $Matches[2].Trim() } }
    }
    if ($lower -match "^(забудь|удали из памяти|forget)\s*[:\-]?\s*(.+)") {
        return @{ intent = "memory_forget"; args = @{ query = $Matches[2].Trim() } }
    }

    # Мультимедиа (ScreenPipe / буфер обмена / заметки)
    if ($lower -match "(сделай скриншот|скриншот экрана|screen shot|screenshot)") { return @{ intent = "screenshot"; args = @{} } }
    if ($lower -match "^(буфер обмена|что в буфере|clipboard|вставь из буфера)") { return @{ intent = "clipboard_get"; args = @{} } }
    if ($lower -match "^(скопируй в буфер|запиши в буфер|copy to clipboard)\s*[:\-]?\s*(.+)") {
        $mm = [regex]::Match($t, '["“”«](.+?)[\"“”»]')
        $txt = if ($mm.Success) { $mm.Groups[1].Value } else { $Matches[2].Trim() }
        return @{ intent = "clipboard_set"; args = @{ text = $txt } }
    }
    if ($lower -match "^(заметка|note|запиши(\\s+заметку?)?|сделай\\s+заметку?|добавь\\s+заметку?|голосовая\\s+заметка)\s*[:\-]?\s*(.+)") {
        return @{ intent = "note_add"; args = @{ text = $Matches[2].Trim() } }
    }
    if ($lower -match "^(покажи заметки|мои заметки|список заметок|show notes)") { return @{ intent = "notes_show"; args = @{} } }

    # NL -> команды (Stenography/ShellGPT)
    if ($lower -match "^(переведи в команды|подбери команду|как сделать|nl2cmd|какая команда для)") {
        $body = $t -replace '^(переведи в команды|подбери команду|как сделать|nl2cmd|какая команда для)\s*[:\-]?\s*', ''
        if (-not $body) { $body = $t }
        return @{ intent = "nl2cmd"; args = @{ text = $body } }
    }

    if ($lower -match "^api\s+(GET|POST|PUT|DELETE|PATCH)\s+(\S+)\s*(.*)") {
        return @{ intent = "api_call"; args = @{ method = $Matches[1].ToUpper(); url = $Matches[2]; body = $Matches[3].Trim() } }
    }

    # Вопросы к базе знаний — «спроси ...»
    if ($lower -match "^(спроси|спроси у модели|объясни|напиши эссе|придумай|сочини|расскажи про|ask kb)\s*[:\-]?\s*(.+)") {
        return @{ intent = "kb_ask"; args = @{ prompt = $Matches[2].Trim() } }
    }

    if ($lower -match "^(расширенная помощь|все навыки|super help|скиллы|умения)") {
        return @{ intent = "super_help"; args = @{} }
    }

    # Веб-навыки (AutoGPT-web / SearchGPT-style)
    if ($lower -match "^(открой сайт|загрузи страницу|прочитай сайт|fetch url|web |открой http)") {
        $mm = [regex]::Match($t, '(https?://\S+|[\w\-\.]+\.(com|org|net|io|ru|dev|ai)[\w\-/]*)')
        if ($mm.Success) { return @{ intent = "web_fetch"; args = @{ url = $mm.Value } } }
    }
    if ($lower -match "^(открой|запусти|open|launch)\s+(не\s+)?(.+)") {
        $m = $Matches[3].Trim()
        $abs = Resolve-SafePath $m
        if ($m -match "\.[a-zA-Z0-9]{1,5}$" -or ($abs -and (Test-Path $abs))) {
            return @{ intent = "file_open"; args = @{ path = $m } }
        }
        return @{ intent = "open_program"; args = @{ target = $m } }
    }

    # Диалог о коде с активным файлом ("измени", "покажи строку N")
    if ($lower -match "^(измени|исправь|замени|поправь|edit|fix)\b") {
        # Явные кавычки имеют приоритет: замени "<найди>" на "<замена>"
        $qAll = [regex]::Matches($t, '["“«](.+?)["”»]')
        if ($qAll.Count -ge 2) {
            $findVal = $qAll[0].Groups[1].Value
            $replVal = $qAll[1].Groups[1].Value
            $pathVal = ""
            # Полный абсолютный путь из текста запроса
            $absM = [regex]::Match($t, '((?:[A-Za-z]:[\\/]|\\\\|~/|/)[^\s"<>|?*]+)')
            if ($absM.Success) { $pathVal = $absM.Groups[1].Value }
            else {
                # Имя файла после «файл/файла/файле/папке ...» (кроме служебного «файл с текстом»)
                $fm = [regex]::Match($t, '(?i)(?:файла?|файле|папк[уи]|папке|file)\s+(?!(?:с\s+текстом|текстом|текст[:\s]))([^\s"“»«]+)')
                if ($fm.Success) { $pathVal = ($fm.Groups[1].Value -replace '[,.:;]+$','') }
            }
            if (-not $pathVal) { $pathVal = $script:context.lastFile }
            return @{ intent = "file_replace"; args = @{ path = $pathVal; find = $findVal; replace = $replVal } }
        }
        # Без кавычек: замени X на Y
        $mm = [regex]::Match($t, '(?i)замени\s*["“«]?(.+?)["”»]?\s+(?:на|=>|->)\s*["“«]?(.+?)["”»]?$')
        if ($mm.Success) {
            $findVal = $mm.Groups[1].Value.Trim()
            $replVal = $mm.Groups[2].Value.Trim()
            $pathVal = ""
            $absM = [regex]::Match($t, '((?:[A-Za-z]:[\\/]|\\\\|~/|/)[^\s"<>|?*]+)')
            if ($absM.Success) { $pathVal = $absM.Groups[1].Value }
            elseif ($fileArg -and $fileArg -ne $findVal -and $fileArg -ne $replVal) { $pathVal = $fileArg }
            if (-not $pathVal) { $pathVal = $script:context.lastFile }
            return @{ intent = "file_replace"; args = @{ path = $pathVal; find = $findVal; replace = $replVal } }
        }
        return @{ intent = "need_clarify_edit"; args = @{} }
    }

    # Файловые операции
    if ($lower -match "^(покажи список|список файлов|ls|dir|что в |покажи папку|покажи файлы|покажи содержимое папки)") {
        return @{ intent = "file_list"; args = @{ path = $fileArg } }
    }
    if ($lower -match "^(прочитай|открой для чтения|покажи содержимое( файла)?|покажи файл|читай|cat|read)\b") {
        return @{ intent = "file_read"; args = @{ path = $fileArg } }
    }
    if ($lower -match "^(создай файл|запиши файл|запиши|сохрани|create file|write|new file)\b") {
        $contentM = [regex]::Match($t, '(?i)(?:текст|содержимое|строку|строки)\s*[:\-–—]?\s*(.+)$')
        if (-not $contentM.Success) { $contentM = [regex]::Match($t, '[“”«"](.*?)[“”»"]\s*$') }
        if (-not $contentM.Success) { $contentM = [regex]::Match($t, '[:\-–—]\s*(.+)$') }
        $body = if ($contentM.Success) { $contentM.Groups[1].Value.Trim(' ', '"', '“', '”', '«', '»') } else { "" }
        return @{ intent = "file_write"; args = @{ path = $fileArg; content = $body } }
    }
    if ($lower -match "^(добавь в файл|допиши|append)\b") {
        $contentM = [regex]::Match($t, '(?i)(?:текст|содержимое)\s*[:\-–—]?\s*(.+)$')
        if (-not $contentM.Success) { $contentM = [regex]::Match($t, '[“”«"](.*?)[“”»"]\s*$') }
        if (-not $contentM.Success) { $contentM = [regex]::Match($t, '[:\-–—]\s*(.+)$') }
        $appBody = if ($contentM.Success) { $contentM.Groups[1].Value.Trim(' ', '"', '“', '”', '«', '»') } else { "" }
        return @{ intent = "file_append"; args = @{ path = $fileArg; content = $appBody } }
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
        "file_delete"     {
            $bak = Backup-BeforeDanger $args2.path
            $r = Invoke-FileOperation (@{action="delete"} + $args2)
            if ($bak) { $r += "`n🛡️ Резервная копия: $bak" }
            return @(@{ response = $r }, $intent)
        }
        "file_mkdir"      { return @(@{ response = Invoke-FileOperation (@{action="mkdir"} + $args2) }, $intent) }
        "file_move"       { return @(@{ response = Invoke-FileOperation (@{action="move"} + $args2) }, $intent) }
        "file_copy"       { return @(@{ response = Invoke-FileOperation (@{action="copy"} + $args2) }, $intent) }
        "file_search"     { return @(@{ response = Invoke-FileOperation (@{action="search"} + $args2) }, $intent) }
        "file_info"       { return @(@{ response = Invoke-FileOperation (@{action="info"} + $args2) }, $intent) }
        "undo"            { return @(@{ response = Undo-LastChange }, $intent) }
        "system_status"   { return @(@{ response = Get-SystemStatus }, $intent) }
        "list_processes"  { return @(@{ response = Get-RunningProcesses }, $intent) }

        # === v4.0: навыки открытых ИИ-систем ===
        "agent_start"       { return @(@{ response = Start-AgentTask $args2.goal }, $intent) }
        "agent_start_empty" { return @(@{ response = "ℹ️ Формат: выполни задачу <цель>, например: `nвыполни задачу создай папку `"project`" и установи requests" }, $intent) }
        "agent_status"      { return @(@{ response = Get-AgentStatus }, $intent) }
        "agent_report"      { return @(@{ response = Get-AgentReport }, $intent) }
        "agent_step"        { return @(@{ response = Complete-AgentStep }, $intent) }
        "agent_cancel"      { return @(@{ response = Cancel-AgentTask }, $intent) }
        "exec_code"         { return @(@{ response = Invoke-AIInterpreterCode -Code $args2.code -LangHint $args2.lang }, $intent) }
        "git_op"            { return @(@{ response = Invoke-GitOperation -GitArgs $args2.gitargs -RepoDir $args2.repo }, $intent) }
        "code_analyze"      {
            $p = if ($args2.path) { $args2.path } elseif ($script:context.lastFile) { $script:context.lastFile } else { $null }
            if (-not $p) { return @(@{ response = "ℹ️ Укажите файл: проанализируй файл main.py (или сначала откройте файл)" }, $intent) }
            return @(@{ response = Get-CodeSummary $p }, $intent)
        }
        "grep_codebase"     { return @(@{ response = Find-InCodebase -Pattern $args2.pattern -Root $args2.root }, $intent) }
        "memory_add"        { return @(@{ response = Add-MemoryFact $args2.fact }, $intent) }
        "memory_recall"     { return @(@{ response = Recall-Memories $args2.query }, $intent) }
        "memory_forget"     { return @(@{ response = Forget-Memory $args2.query }, $intent) }
        "screenshot"        { return @(@{ response = Take-Screenshot }, $intent) }
        "clipboard_get"     { return @(@{ response = Get-ClipboardText }, $intent) }
        "clipboard_set"     { return @(@{ response = Set-ClipboardText $args2.text }, $intent) }
        "note_add"          { return @(@{ response = Add-VoiceNote $args2.text }, $intent) }
        "notes_show"        { return @(@{ response = Show-Notes }, $intent) }
        "nl2cmd"            { return @(@{ response = Translate-NlToCommands $args2.text }, $intent) }
        "web_fetch"         { return @(@{ response = Invoke-WebRequestSkill $args2.url }, $intent) }
        "api_call"          { return @(@{ response = Invoke-ApiCall -Method $args2.method -Url $args2.url -Body $args2.body }, $intent) }
        "kb_ask"            {
            # отвечаем из встроенной базы знаний
            $kbHit = $null
            foreach ($key in $script:knowledgeBase.Keys) {
                foreach ($kw in $script:knowledgeBase[$key].keywords) {
                    if ($args2.prompt.ToLower() -match ('(?i)\b' + [regex]::Escape($kw) + '\b')) { $kbHit = $script:knowledgeBase[$key].text; break }
                }
                if ($kbHit) { break }
            }
            $fallback = if ($kbHit) { "📚 Из базы знаний:`n$kbHit" } else { "💭 Такого нет в моей базе знаний. Попробуйте переформулировать вопрос или обратитесь к навыкам: «помощь»." }
            return @(@{ response = $fallback }, $intent)
        }
        "super_help"        { return @(@{ response = Get-SuperHelp }, $intent) }
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
        return @{ response = "$greeting! Я J — ваш AI-ассистент v5.0 (навыки AutoGPT, Open Interpreter, Aider, MemGPT и др.). Умею: файлы/папки, команды, выполнение кода (exec python ...), автономные задачи (выполни задачу ...), память (запомни ...), git, веб (api GET ...), скриншоты, заметки. Напишите «помощь» или «все навыки»."; intent = "greeting" }
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
        return @{ response = Get-SuperHelp; intent = "help" }
    }

    # База знаний расширена: языки, фреймворки, DevOps, наука (как у открытых ассистентов)
    $extraTopics = @{
        "rust" = "🦀 Rust — системный язык с гарантией безопасности памяти без сборщика мусора. Используется в ОС, браузерах (Firefox), WASM."
        "golang" = "🐹 Go — язык Google: простая конкурентность (goroutines), быстрая компиляция, микросервисы и DevOps-инструменты (Docker написан на Go)."
        "docker" = "🐳 Docker — контейнеризация приложений. Основные команды: docker build, docker run, docker-compose up. Изолирует приложение со всеми зависимостями."
        "kubernetes" = "☸️ Kubernetes — оркестрация контейнеров: масштабирование, самовосстановление, service discovery. Объекты: Pod, Deployment, Service."
        "sql" = "🗄️ SQL — язык запросов к базам данных: SELECT, JOIN, GROUP BY. Диалекты: PostgreSQL, MySQL, SQLite, MSSQL."
        "linux" = "🐧 Linux — открытая ОС: bash, пакетные менеджеры (apt/yum/pacman), systemd, права (chmod/chown). Основа серверов и Android."
        "android" = "🤖 Android — ОС на ядре Linux. Разработка: Kotlin/Java + Android Studio; ADB для управления устройством; Termux — Linux-средa+PowerShell на телефоне."
        "swift" = "🍎 Swift — язык Apple-экосистемы (iOS/macOS). SwiftUI для интерфейсов; Xcode — среда разработки. Альтернатива: React Native/Flutter."
        "machine learning" = "🧠 ML-фреймворки: PyTorch и TensorFlow/Keras для нейросетей, scikit-learn для классики, Hugging Face Transformers для LLM."
        "prompt engineering" = "✍️ Промпт-инжиниринг: чёткая роль, примеры (few-shot), цепочка рассуждений (chain-of-thought), структурированный вывод (JSON)."
        "git" = "🌿 Git — системы контроля версий: commit, branch, merge, rebase, stash. Спросите ассистента: git status / git log / git commit -m msg."
        "api" = "🔌 REST API: методы GET/POST/PUT/DELETE, коды 200/404/500, JSON. Проверьте сами: api GET https://api.github.com"
    }

    # Поиск в базе знаний (основная + расширенная тематическая)
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
    foreach ($topicKey in $extraTopics.Keys) {
        if ($lower -match [regex]::Escape($topicKey)) {
            $script:context.lastTopic = $script:context.topic
            $script:context.topic = $topicKey
            Write-ActionLog "KB_ANSWER" $topicKey "Расширенная база знаний"
            return @{ response = $extraTopics[$topicKey]; intent = "kb:$topicKey" }
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
    return @{ response = "Я вас понял. Я умею всё: файлы/команды/код (exec), автономные задачи (AutoGPT-стиль), память (MemGPT-стиль), git, анализ кода (Aider/SWE-agent), веб и API, скриншоты, буфер обмена, заметки, база знаний (python, AI, docker, kubernetes, sql и др.). Напишите «помощь» или «все навыки».$historyHint"; intent = "default" }
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
                # Служебный GET-запрос (например проверка доступности сервера)
                if ($request.HttpMethod -eq "GET") {
                    $pingResp = @{ success = $true; response = "pong"; timestamp = Get-Date -Format "o" } | ConvertTo-Json
                    $pingBytes = [System.Text.Encoding]::UTF8.GetBytes($pingResp)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $pingBytes.Length
                    $response.OutputStream.Write($pingBytes, 0, $pingBytes.Length)
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
Write-Host "   Версия 4.0 SUPER SKILLS" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Start-Server
