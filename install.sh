#!/bin/bash
# Установка Astra Linux Helper в /opt/astra-helper + ярлык в меню.
# Запуск:  sudo bash install.sh
set -e
[ "$(id -u)" -ne 0 ] && { echo "Запустите от root:  sudo bash install.sh"; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"
DST=/opt/astra-helper

echo "== Копирую файлы в $DST"
mkdir -p "$DST"
cp -f "$SRC/astra-helper" "$SRC/astra-fixer" "$SRC/astra_helper_gui.py" "$SRC/astra_fixer_gui.py" "$SRC/astra-doctor.sh" "$SRC/uninstall.sh" "$DST/"
cp -f "$SRC"/*.svg "$DST/" 2>/dev/null || true
chmod 755 "$DST/astra-helper" "$DST/astra-fixer" "$DST/astra-doctor.sh" "$DST/uninstall.sh"
chmod 644 "$DST/astra_helper_gui.py" "$DST/astra_fixer_gui.py"
ln -sf "$DST/astra-helper" /usr/local/bin/astra-helper
ln -sf "$DST/astra-fixer" /usr/local/bin/astra-fixer

echo "== Зависимости"
set +e
need=""
python3 -c 'import tkinter' >/dev/null 2>&1 || need="$need python3-tk"
command -v host >/dev/null 2>&1 || command -v dig >/dev/null 2>&1 || command -v nslookup >/dev/null 2>&1 || need="$need dnsutils"
if [ -n "$need" ]; then
  echo "Устанавливаю из репозитория Astra:$need"
  apt-get install -y $need || { apt-get update >/dev/null 2>&1; apt-get install -y $need; }
  python3 -c 'import tkinter' >/dev/null 2>&1 \
    || echo "!! python3-tk не установился (нет репозитория/диска Astra). Программа будет работать в текстовом режиме: astra-helper --text"
else
  echo "Все зависимости уже есть"
fi
set -e

echo "== Ярлык в меню"
cat > /usr/share/applications/astra-helper.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Astra Linux Helper
Name[ru]=Astra Helper — диагностика
Comment=Проверка типичных проблем Astra Linux и советы по исправлению
Exec=$DST/astra-helper
Icon=$( [ -f "$DST/astra-helper.svg" ] && echo "$DST/astra-helper.svg" || echo utilities-system-monitor )
Terminal=false
Categories=System;Settings;
EOF
cat > /usr/share/applications/astra-fixer.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Astra Fixer
Name[ru]=Astra Fixer — исправление
Comment=Исправление типичных проблем Astra Linux готовыми командами
Exec=$DST/astra-fixer
Icon=$DST/astra-fixer.svg
Terminal=false
Categories=System;Settings;
EOF
chmod 644 /usr/share/applications/astra-helper.desktop /usr/share/applications/astra-fixer.desktop

echo
echo "Готово. Меню «Пуск» → Системные → Astra Helper (диагностика) и Astra Fixer (исправление)"
echo "В терминале:  astra-helper  /  astra-fixer   (без графики: --text)"
echo "Удаление:  sudo $DST/uninstall.sh"
