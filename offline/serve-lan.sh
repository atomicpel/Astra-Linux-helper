#!/bin/bash
# Раздаёт собранные зависимости по локальной сети как apt-репозиторий (на сервере).
#   bash serve-lan.sh [порт]      (по умолчанию 8080; остановка — Ctrl+C)
# Если на сервере уже есть веб-сервер — можно просто положить папку deps в его каталог.
cd "$(dirname "$0")/deps" 2>/dev/null || { echo "Нет папки deps — сначала выполните: sudo bash collect-deps.sh"; exit 1; }
PORT=${1:-8080}
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo "Раздаю $(pwd) на порту $PORT. Доступные версии: $(ls -d */ | tr -d / | tr '\n' ' ')"
echo "На клиентах:  sudo bash add-lan-repo.sh ${IP:-<IP_сервера>} $PORT"
echo "(не забудьте открыть порт $PORT во входящих правилах межсетевого экрана сервера)"
exec python3 -m http.server "$PORT"
