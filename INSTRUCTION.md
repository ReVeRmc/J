# 📘 J AI Assistant — Полная инструкция по развёртыванию и работе

Версия ассистента: **4.0 SUPER SKILLS** · Файл инструкции обновлён: 13.10.2026

J AI Assistant — локальный серверный ИИ-помощник на PowerShell с HTTP API.
Умеет работать с файлами, кодом, терминалом, запускать программы, выполнять
код на Python/Node.js/PowerShell, вести автономные задачи (агентный режим),
хранить долговременную память и логировать каждый шаг. Внешние LLM не
используются — вся логика работает локально.

---

## 1. Состав проекта

| Файл | Назначение |
|---|---|
| `server.ps1` | Единственный исполняемый модуль: HTTP-сервер + вся AI-логика (навыки, парсер команд, память, логгер) |
| `start-server.bat` | Обёртка запуска для Windows: автозапрос прав администратора (UAC) + запуск `server.ps1` |
| `J-AI-Assistant.apk` | Готовое Android-приложение — минималистичный клиент (строка чата + большая голосовая кнопка), исходники в `android-client/` |
| `README.md` | Краткое описание возможностей |
| `INSTRUCTION.md` | Эта инструкция |
| `logs/` | Создаётся автоматически: журнал диалога и действий |

Клиентских файлов нет — взаимодействие идёт только через HTTP API.

---

## 2. Системные требования

### Обязательное
- **PowerShell 5.1+** (Windows 10/11 — встроен) или **PowerShell 7+ (`pwsh`)** для macOS/Linux/Android;
- Свободный TCP-порт (по умолчанию **8080**);
- Права администратора/root — для полного доступа к системе (рекомендуется).

### Опциональное (расширяет навыки)
| Инструмент | Что открывает | Установка |
|---|---|---|
| Python 3.x | навык «выполни код на python» | python.org / `winget install Python.Python.3.12` |
| Node.js 18+ | «выполни код на node» | nodejs.org / `winget install OpenJS.NodeJS.LTS` |
| Git | git-навыки (статус, коммиты, диффы) | `winget install Git.Git` |
| curl | веб-навыки (загрузка файлов, API) | встроен в Win10+/Linux |

Без опций ассистент полностью работоспособен: файлы, терминал, память,
агент, база знаний — всё доступно из коробки.

---

## 3. Развёртывание

### 3.1 Windows 10/11 (основной сценарий)

```powershell
# 1. Получите файлы проекта (клонирование или копирование папки)
git clone <путь-или-url-репозитория> "C:\Tools\jai"
cd C:\Tools\jai

# 2. Запуск в один клик (сам запросит права администратора через UAC):
.\start-server.bat

#    Если .bat блокируется политикой выполнения:
#    Right-click → Properties → Unblock, либо запускайте напрямую:
powershell -ExecutionPolicy Bypass -File .\server.ps1
```

Успешный запуск выглядит так:

```
============================================
   J AI Assistant - Серверная часть
   Версия 4.0 SUPER SKILLS
============================================
[SUCCESS] Сервер доступен на http://localhost:8080
[SUCCESS] Сервер запущен и ожидает подключений...
```

### 3.2 macOS / Linux

```bash
# Установка PowerShell 7 (один раз):
# macOS:  brew install --cask powershell
# Ubuntu: sudo snap install powershell --classic
# Debian: см. https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux

pwsh -File ./server.ps1                  # обычный запуск
sudo pwsh -File ./server.ps1             # полный доступ к системе (аналог root)
pwsh -File ./server.ps1 -Port 9000       # другой порт
```

### 3.3 Android (Termux)

```bash
pkg update && pkg install powershell git
git clone <репозиторий> && cd <папка>
pwsh -File ./server.ps1 -ServerHost 0.0.0.0 -Port 8080
```

Доступ к хранилищу телефона: `termux-setup-storage` (файлы появятся в `~/storage`).
Полный root на Android возможен только на рутованном устройстве (`su`).

### 3.4 iOS (iPhone/iPad)

Системные ограничения Apple (песочница, запрет фоновых серверов) не позволяют
запустить полноценного агента на самом устройстве. Варианты:
- подключить iPhone к запущенному серверу в локальной сети (см. п. 3.5);
- использовать Mac как сервер (сценарий 3.2).

### 3.5 Доступ по сети (другие устройства в той же Wi-Fi/LAN сети)

```powershell
# На машине-сервере:
pwsh -File ./server.ps1 -ServerHost 0.0.0.0 -Port 8080
```

Разрешите входящее подключение в брандмауэре:

```powershell
netsh advfirewall firewall add rule name="J AI Assistant" dir=in action=allow protocol=TCP localport=8080
```

С других устройств обращайтесь по IP сервера, например `http://192.168.1.20:8080`.

⚠️ **Безопасность:** сервер не имеет аутентификации и выполняет команды от
имени своего пользователя. Экспонируйте его только в доверенной локальной
сети, не пробрасывайте порт наружу (NAT/интернет) и останавливайте, когда
он не нужен.

### 3.6 Автозапуск при старте системы (опционально)

**Windows (Планировщик задач, с правами администратора):**

```powershell
$action = New-ScheduledTaskAction -Execute "powershell" `
  -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Tools\jai\server.ps1"
$trigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName "JAiAssistant" -Action $action -Trigger $trigger -RunLevel Highest
```

**Linux/macOS (systemd, пример для Linux):**

```ini
# /etc/systemd/system/jai.service
[Unit]
Description=J AI Assistant
After=network.target

[Service]
ExecStart=/usr/bin/pwsh -File /opt/jai/server.ps1 -ServerHost 0.0.0.0
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now jai
```

---

## 4. Проверка установки

```bash
# 1. Жив ли сервер (GET возвращает JSON {"response":"pong"}):
curl http://localhost:8080/

# 2. Отправьте первое сообщение (POST с JSON-телом):
curl -X POST http://localhost:8080/ -H "Content-Type: application/json" -d "{\"message\":\"привет\"}"

# 3. Полный список навыков:
curl -X POST http://localhost:8080/ -H "Content-Type: application/json" -d "{\"message\":\"помощь\"}"

# 4. Проверьте, что создались логи: logs/dialog.jsonl и logs/actions.log
```

Все четыре шага должны завершиться успешно — установка готова.

---

## 5. Формат API

### Запрос

```
POST http://<сервер>:<порт>/
Content-Type: application/json

{ "message": "<текст команды или вопроса>" }
```

### Ответ

```json
{
  "success": true,
  "response": "текст ответа ассистента",
  "intent": "HELP",              // распознанное намерение
  "context": { ... },            // активный файл, последняя команда и т.д.
  "timestamp": "2026-10-13T12:00:00"
}
```

Служебный `GET /` → `{"success":true,"response":"pong"}` — проверка доступности.

### Клиенты на выбор

**PowerShell:**
```powershell
Invoke-RestMethod -Uri http://localhost:8080/ -Method Post `
  -ContentType "application/json; charset=utf-8" `
  -Body ([pscustomobject]@{ message = "помощь" } | ConvertTo-Json)
```

**Python:**
```python
import requests
r = requests.post("http://localhost:8080/", json={"message": "покажи список файлов"})
print(r.json()["response"])
```

**JavaScript (fetch):**
```javascript
const r = await fetch("http://localhost:8080/", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ message: "который час" })
});
console.log((await r.json()).response);
```

**Терминал Windows (cmd):**
```bat
powershell -Command "(irm http://localhost:8080/ -Method Post -ct 'application/json' -b '{\"message\":\"помощь\"}').response"
```

---

## 6. Работа с ассистентом: все возможности

Пишите команды обычным языком (рус/англ). Ниже — полная карта навыков.

### 6.1 Диалог и знания
```
привет · пока · спасибо · который час · какое сегодня число
помощь                                  — полный список команд
спроси что такое рекурсия               — встроенная база знаний
```

### 6.2 Файлы и папки (любой путь в системе)
```
покажи список файлов C:\Users\Ivan\Documents
покажи файл main.py                     — читает и делает файл «активным»
создай файл заметки.txt с текстом Привет
добавь в config.json строку "port": 8080
замени в app.js "var x" на "let x"
удали файл temp.log                      mkdir создай_папку
перемести a.txt в C:\backup              скопируй фото.jpg в D:\\img
найди *.ps1 в C:\Scripts                 информация о файле readme.md
отмени                                   — возврат последнего изменения файла
```
Активный файл запоминается: после «покажи файл X» можно говорить
«измени», «замени … на …», «покажи снова» без повтора пути.

### 6.3 Терминал и программы
```
выполни ipconfig /all                    выполни git status
запусти notepad                          открой calc.exe
открой https://example.com               запусти python script.py
повтори                                  — повтор последней команды
```

### 6.4 Выполнение кода (Open Interpreter-стиль)
```
выполни код на python: print(2**10)
выполни код на node: console.log("hi")
выполни код на powershell: Get-Date
```
Ассистент сам выбирает интерпретатор; если он не установлен — подскажет команду установки.

### 6.5 Анализ кода (Aider/SWE-agent-стиль)
```
проанализируй файл server.ps1            найди функцию Start-Server в C:\src
найди "TODO" во всех *.py в C:\project    покажи структуру проекта
```

### 6.6 Git
```
git статус                               git коммит "fix: баг"
git diff                                 git лог
```

### 6.7 Автономный агент (AutoGPT/BabyAGI-стиль)
```
создай задачу: настроить окружение python
план                                     — очередь и статус задач
выполни задачу 1                         — запуск декомпозиции по шагам
```

### 6.8 Память (MemGPT-стиль, сохраняется между перезапусками)
```
запомни мой проект лежит в D:\work
вспомни про проект                       список памяти
забудь про проект
```

### 6.9 Веб (через curl/Invoke-RestMethod)
```
api GET https://api.github.com/events
скачай файл https://…/archive.zip в C:\Downloads
```

### 6.10 Система и мультимедиа
```
статус системы                           какие процессы запущены
сделай скриншот                          заметка куплю молоко
выключи звук                             перезагрузи проводник
```

---

## 7. Логирование

Всё происходит на сервере и записывается в `logs/`:

| Файл | Содержание |
|---|---|
| `logs/dialog.jsonl` | Каждая реплика: ISO-timestamp, номер хода, роль, распознанный intent, текст (JSON Lines — удобно анализировать) |
| `logs/actions.log` | Каждое действие с результатом: READ_FILE, CREATE_FILE, REPLACE_IN_FILE, RUN_CMD, EXEC_CODE, GIT_OP, AGENT_TASK, MEMORY_SET, UNDO_*, ERROR… |
| консоль | Live-лог уровней INFO/SUCCESS/WARNING/ERROR |

Пример анализа журнала:
```powershell
Get-Content logs\dialog.jsonl | ConvertFrom-Json | Where-Object intent -eq "RUN_CMD"
tail -n 50 logs/actions.log          # Linux/macOS
```

Логи не попадают в git (см. `.gitignore`) и могут быть удалены в любой момент — папка создастся заново.

---

## 8. Параметры запуска

| Параметр | По умолчанию | Описание |
|---|---|---|
| `-Port` | `8080` | TCP-порт HTTP API |
| `-ServerHost` | `localhost` | Интерфейс: `localhost` — только эта машина; `0.0.0.0` — вся сеть |

```powershell
pwsh -File server.ps1 -Port 9000 -ServerHost 0.0.0.0
```

Остановка: `Ctrl+C` в окне сервера (логи фиксируют остановку).

---

## 9. Устранение неполадок

| Симптом | Решение |
|---|---|
| `Only each host may use this port` / порт занят | Смените порт: `-Port 8081`, либо освободите: `netstat -ano \| findstr :8080` → завершите процесс |
| `Access is denied` при запуске сервера | HttpListener требует админ-прав (или резервацию URL: `netsh http add urlacl url=http://+:8080/ user=%USERNAME%`) |
| Блокировка скрипта (`running scripts is disabled`) | `powershell -ExecutionPolicy Bypass -File .\server.ps1` |
| Кириллица «кракозябрами» в cmd | `chcp 65001` (в `start-server.bat` уже есть) или используйте PowerShell 7 |
| `curl: (7) Connection refused` | Сервер не запущен / другой порт / проверьте `curl http://localhost:8080/` → pong |
| Другое устройство не видит сервер | Запустите с `-ServerHost 0.0.0.0` и добавьте правило брандмауэра (п. 3.5) |
| Навык кода отвечает «интерпретатор не найден» | Установите Python/Node (таблица п. 2) и перезапустите сервер |
| Ошибка в одном запросе роняет диалог | Не должна: каждая обработка обёрнута в try/catch, сервер продолжает работать; проверьте `logs/actions.log` |

---

## 10. Безопасная эксплуатация

1. Сервер выполняет любые действия от имени своего пользователя и **не имеет авторизации** — держите порт закрытым в WAN и включайте сетевой режим (`0.0.0.0`) только осознанно.
2. Для повседневной работы достаточно запуска **без root/admin**: ограничены лишь системные разделы. Полные права включайте, когда нужно менять системные файлы.
3. Перед деструктивными операциями (удаление, перезапись) ведите журнал `actions.log` под рукой; навык «отмени» вернёт последнее изменение файла.
4. Периодически очищайте `logs/` и память («забудь …»), если они перестают быть нужными.

---

## 11. Обновление и откат

```bash
git pull                              # обновление
git log --oneline                     # история версий
git checkout <commit> -- server.ps1   # откат конкретного файла
```

После обновления `server.ps1` просто перезапустите сервер — конфигурация
(порт/хост) задаётся параметрами, состояние (память, контекст) хранится в файлах
в папке проекта и переживает перезапуск.
