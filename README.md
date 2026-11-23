# RouteFork

RouteFork запускает Codex и Telegram через общий профиль Xray из строки меню macOS. Для Codex используется локальный HTTP-прокси, для Telegram — SOCKS5. Подключениями можно управлять отдельно.

## Начало работы

Нужен Mac с Apple Silicon и macOS 14 или новее. Скачай ZIP на странице [Releases](https://github.com/dkutugin3/routefork/releases) и распакуй приложение. Бета-сборка подписана ad hoc. Для запуска с обычными настройками Gatekeeper собери приложение локально по инструкции ниже. [Требования Apple к распространению приложений](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

1. Открой RouteFork и выбери **Подключение → Ключ Xray**. Поддерживаются VLESS gRPC/TLS, TCP/TLS и TCP/REALITY. Профиль хранится в Связке ключей macOS.
2. Выбери **Включить прокси Codex** и подтверди перезапуск Codex. Эта конфигурация использует локальный app-server Codex.
3. Выбери **Открыть Telegram через прокси** и подтверди SOCKS5 в Telegram. Для обычного подключения выключи SOCKS5 в настройках Telegram.

Xray устанавливает соединение с сервером через Wi-Fi или Ethernet. Для доменного имени сервера приложение использует системный DNS. Если прямое соединение недоступно, RouteFork сообщает об ошибке. При выборе уже запущенного локального HTTP- или SOCKS5-прокси за его маршрут отвечает приложение, которое его запустило.

## Сборка

Установи Xcode Command Line Tools. Скрипт проверяет SHA-256 архива Xray перед сборкой.

```sh
mkdir -p build
curl --fail --location \
  https://github.com/XTLS/Xray-core/releases/download/v26.10.31/Xray-macos-arm64-v8a.zip \
  --output build/Xray-macos-arm64-v8a.zip
bash build-app.sh build/Xray-macos-arm64-v8a.zip build/RouteFork.app
open build/RouteFork.app
```

В пакет входит [Xray-core v26.10.31](https://github.com/XTLS/Xray-core/tree/v26.10.31) под лицензией MPL 2.0. Лицензия и ссылка на исходники Xray лежат в `Contents/Resources`.
