#!/bin/bash
# Подключает локальный репозиторий с сервера и ставит Astra Linux Helper со всеми зависимостями.
#   sudo bash add-lan-repo.sh <IP_сервера> [порт]
[ "$(id -u)" -ne 0 ] && { echo "Запустите от root:  sudo bash $0 <IP_сервера>"; exit 1; }
SRV="$1"; PORT="${2:-8080}"
[ -z "$SRV" ] && { echo "Укажите адрес сервера:  sudo bash $0 192.168.1.10"; exit 1; }
s="$(head -1 /etc/astra_version 2>/dev/null) $(head -1 /etc/astra/build_version 2>/dev/null)"
case "$s" in *1.8*) V=1.8 ;; *1.7*) V=1.7 ;; *1.6*|*molensk*) V=1.6 ;; *) V=other ;; esac
URL="http://$SRV:$PORT/$V-$(dpkg --print-architecture)"
echo "deb [trusted=yes] $URL ./" > /etc/apt/sources.list.d/astra-helper-lan.list
echo "Подключён репозиторий: $URL"
apt-get update -o Dir::Etc::sourcelist=/dev/null -o Dir::Etc::sourceparts=/etc/apt/sources.list.d -o APT::Get::List-Cleanup=0 \
  || { echo "!! Сервер недоступен или нет папки $V-$(dpkg --print-architecture) — соберите deps на машине с Astra $V"; exit 1; }
apt-get install -y astra-helper python3-tk && echo "Готово. Запуск: Пуск → Системные → Astra Helper, или  astra-helper"
