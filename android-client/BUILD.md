# Сборка APK J AI Assistant

## Требования
- JDK 17+, Android SDK (platforms;android-34, build-tools;34.0.0), Gradle 8.x

## Команды
```bash
echo "sdk.dir=/path/to/android-sdk" > local.properties
gradle assembleRelease
# Подпись:
keytool -genkeypair -v -keystore keystore/jai.keystore -alias jai -keyalg RSA -keysize 2048 -validity 10000
zipalign -f 4 app/build/outputs/apk/release/app-release-unsigned.apk aligned.apk
apksigner sign --ks keystore/jai.keystore --out J-AI-Assistant.apk aligned.apk
```

Готовый собранный APK лежит в корне репозитория: `J-AI-Assistant.apk`
(подписан тестовым ключом `android-client/keystore/jai.keystore`,
пароль keystore/key: `jaipass123`, alias: `jai`).

## Установка на телефон
1. Скопируйте `J-AI-Assistant.apk` на устройство.
2. Разрешите установку из неизвестных источников.
3. Откройте APK → Установить.
Или через ADB: `adb install -r J-AI-Assistant.apk`

## Конфигурация клиента
При первом запуске введите адрес сервера (поле сверху), например
`http://192.168.0.100:8080` и нажмите ✓. Адрес сохраняется между запусками.
Телефон и ПК должны быть в одной Wi-Fi сети. На ПК сервер нужно запустить
с доступом из сети: `pwsh server.ps1 -ServerHost +` (Windows — от администратора).

## Управление
- Большая круглая кнопка по центру — голосовой диалог (нажмите, говорите,
  нажмите ещё раз для остановки). Ответ озвучивается.
- Долгое нажатие на кнопку микрофона — включить/выключить озвучивание ответов.
- Строка внизу — текстовый ввод команды + кнопка отправки.
