# Диагностика проблем с запуском J - AI Assistant

## Проблема: Приложение показывает только splash screen и пустой экран

### Шаг 1: Проверьте логи приложения

Логи находятся в:
```
%APPDATA%\j-ai-assistant\app.log
```

Откройте этот файл и найдите следующие строки:
- `[J-AI] main.tsx загружен`
- `[J-AI] App.tsx загружен`
- `[J-AI] App компонент инициализирован`
- `[J-AI] App рендерится`

Если этих строк нет - React не загружается.

### Шаг 2: Запустите приложение из командной строки

Откройте командную строку (CMD) и выполните:

```cmd
cd "путь\к\установке\J - AI Assistant"
.\J - AI Assistant.exe
```

Это покажет все ошибки в консоли.

### Шаг 3: Откройте DevTools

Когда приложение запустится (даже если экран пустой):
1. Нажмите `Ctrl+Shift+I` (или `F12`)
2. Откроется панель разработчика
3. Перейдите на вкладку **Console**
4. Найдите ошибки (красным цветом)

Ожидаемые сообщения:
```
[J-AI] main.tsx загружен
[J-AI] React version: 18.x.x
[J-AI] Root element: <div id="root">...</div>
[J-AI] Создаю React root...
[J-AI] React root создан, рендерю App...
[J-AI] App.tsx загружен
[J-AI] App компонент инициализирован
[J-AI] App useEffect запущен
[J-AI] App рендерится, count: 0
[J-AI] App отрендерен успешно
```

### Шаг 4: Проверьте вкладку Network

В DevTools перейдите на вкладку **Network**:
1. Обновите страницу (`Ctrl+R` или `F5`)
2. Проверьте что загружаются файлы:
   - `index.html`
   - `assets/index-*.js`
   - `assets/index-*.css`

Если файлы не загружаются (статус 404 или другой) - проблема с путями.

### Шаг 5: Проверьте вкладку Sources

В DevTools перейдите на вкладку **Sources**:
1. Разверните папку `file://`
2. Проверьте что видны файлы:
   - `dist/index.html`
   - `dist/assets/index-*.js`
   - `dist/assets/index-*.css`

### Шаг 6: Проверьте содержимое asar архива

В папке установки выполните:

```cmd
npx asar list resources\app.asar
```

Должны быть файлы:
```
/dist/index.html
/dist/assets/index-*.js
/dist/assets/index-*.css
/electron/main.js
/electron/preload.js
/package.json
```

### Шаг 7: Проверьте пути в main.js

В логах приложения найдите строки:
```
Is packaged: true
__dirname: ...
app.getAppPath(): ...
Loading production file: ...
Index exists: true/false
```

Если `Index exists: false` - проблема с путями.

### Шаг 8: Попробуйте development режим

В папке проекта выполните:

```powershell
npm run electron:dev
```

Если в dev режиме всё работает, но в packaged нет - проблема с путями или упаковкой.

### Шаг 9: Проверьте CSP (Content Security Policy)

В DevTools Console найдите ошибки вида:
```
Refused to execute script because it violates the following Content Security Policy directive
```

Если такие ошибки есть - нужно настроить CSP в index.html.

### Шаг 10: Проверьте антивирус

Некоторые антивирусы блокируют выполнение JavaScript в Electron приложениях.

Решение:
1. Добавьте папку установки в исключения антивируса
2. Временно отключите антивирус для проверки

## Частые проблемы и решения

### Проблема: "Element #root не найден"

**Решение:** Проверьте index.html в папке dist. Должен быть элемент:
```html
<div id="root"></div>
```

### Проблема: "Cannot find module"

**Решение:** Переустановите зависимости:
```powershell
rm -r node_modules
rm package-lock.json
npm install
```

### Проблема: "Unexpected token <"

**Решение:** Проблема с путями к JS/CSS файлам. Проверьте vite.config.ts:
```typescript
export default defineConfig({
  base: './', // Обязательно относительные пути!
  // ...
});
```

### Проблема: Белый экран без ошибок

**Решение:** Проверьте CSS. Возможно стили скрывают контент:
```css
#root {
  display: block !important;
  visibility: visible !important;
}
```

### Проблема: "Failed to load resource: net::ERR_FILE_NOT_FOUND"

**Решение:** Проблема с путями. Проверьте:
1. vite.config.ts: `base: './'`
2. index.html: `<script type="module" src="/src/main.tsx"></script>`
3. В dist/index.html пути должны быть относительными: `./assets/...`

## Переустановка приложения

Если ничего не помогло:

1. Удалите приложение через "Программы и компоненты"
2. Удалите папку: `%APPDATA%\j-ai-assistant`
3. Пересоберите .exe:
   ```powershell
   npm run electron:build
   ```
4. Установите заново из `release/J - AI Assistant-2.0.0-Setup.exe`

## Получение помощи

Если проблема не решена:

1. Откройте DevTools (`Ctrl+Shift+I`)
2. Перейдите на вкладку **Console**
3. Скопируйте все сообщения (особенно красные ошибки)
4. Откройте файл `%APPDATA%\j-ai-assistant\app.log`
5. Скопируйте содержимое
6. Предоставьте эту информацию для анализа
