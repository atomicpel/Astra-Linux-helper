#!/bin/bash
# Установка Astra Linux Helper без интернета.
#   sudo bash install-offline.sh
# Берёт зависимости из deps/<версия>-<архитектура>/ (собраны collect-deps.sh),
# ставит только то, чего в системе нет, и затем сам astra-helper.
[ "$(id -u)" -ne 0 ] && { echo "Запустите от root:  sudo bash $0"; exit 1; }
cd "$(dirname "$0")"

detect_ver() {
  local s; s="$(head -1 /etc/astra_version 2>/dev/null) $(head -1 /etc/astra/build_version 2>/dev/null)"
  case "$s" in *1.8*) echo 1.8 ;; *1.7*) echo 1.7 ;; *1.6*|*molensk*) echo 1.6 ;; *) echo other ;; esac
}
V=$(detect_ver); ARCH=$(dpkg --print-architecture)
DEP="deps/$V-$ARCH"
echo "== Astra $V ($ARCH)"

installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

if python3 -c 'import tkinter' >/dev/null 2>&1; then
  echo "python3-tk уже есть — зависимости не нужны"
elif ls "$DEP"/*.deb >/dev/null 2>&1; then
  TODO=()
  for d in "$DEP"/*.deb; do
    p=$(dpkg-deb -f "$d" Package)
    [ "$p" = "astra-helper" ] && continue
    installed "$p" || TODO+=("$d")
  done
  echo "== Ставлю зависимости: ${#TODO[@]} пакетов из $DEP"
  if [ ${#TODO[@]} -gt 0 ] && ! dpkg -i "${TODO[@]}"; then
    echo
    echo "!! Часть пакетов не встала. Обычно это значит, что deps собраны на другой версии или другом"
    echo "   обновлении Astra. Соберите их на машине с точно такой же сборкой ($(head -1 /etc/astra/build_version 2>/dev/null))."
    dpkg --configure -a
  fi
else
  echo "!! Нет папки $DEP с зависимостями."
  echo "   Пробую поставить python3-tk из подключённого репозитория (диск/локальный сервер)..."
  apt-get install -y python3-tk || echo "   Не вышло — программа будет работать в текстовом режиме (astra-helper --text)."
fi

DEB=$(ls -1 "$DEP"/astra-helper_*_all.deb ../dist/astra-helper_*_all.deb astra-helper_*_all.deb 2>/dev/null | sort -V | tail -1)
[ -z "$DEB" ] && { echo "!! Не найден astra-helper_*_all.deb"; exit 1; }
echo "== Ставлю $DEB"
dpkg -i "$DEB" || { echo "!! Ошибка установки astra-helper"; exit 1; }

echo
python3 -c 'import tkinter' >/dev/null 2>&1 && echo "Готово. Запуск: Пуск → Системные → Astra Helper, или  astra-helper" \
  || echo "Установлено без графики. Запуск проверок:  astra-helper --text"
