#!/bin/bash
# Сборка пакета astra-helper_<версия>_all.deb (для разработчика).
# Сжатие xz — чтобы пакет ставился и на Astra 1.6 (dpkg 1.18 не знает zstd).
set -e
cd "$(dirname "$0")"
VER=$(grep -E '^VERSION *=' astra_helper_gui.py | cut -d'"' -f2)
B=$(mktemp -d)
P="$B/astra-helper"
mkdir -p "$P/DEBIAN" "$P/opt/astra-helper" "$P/usr/bin" "$P/usr/share/applications"
install -m 755 astra-helper astra-doctor.sh "$P/opt/astra-helper/"
install -m 644 astra_helper_gui.py astra-helper.svg README.md "$P/opt/astra-helper/"
ln -s /opt/astra-helper/astra-helper "$P/usr/bin/astra-helper"
cat > "$P/usr/share/applications/astra-helper.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Astra Linux Helper
Name[ru]=Astra Helper — диагностика и исправление
Comment=Проверка и исправление типичных проблем Astra Linux
Exec=/opt/astra-helper/astra-helper
Icon=/opt/astra-helper/astra-helper.svg
Terminal=false
Categories=System;Settings;
EOF
SIZE=$(du -sk "$P" | cut -f1)
cat > "$P/DEBIAN/control" <<EOF
Package: astra-helper
Version: $VER
Section: admin
Priority: optional
Architecture: all
Depends: bash, python3
Recommends: python3-tk, dnsutils | bind9-dnsutils | bind9-host
Installed-Size: $SIZE
Maintainer: Pavel Dudin <atomicpel@yandex.ru>
Homepage: https://github.com/atomicpel/Astra-Linux-helper
Description: Диагностика и исправление типичных проблем Astra Linux SE 1.6/1.7/1.8
 Кнопка «Проверить всё»: список проблем и пошаговые инструкции.
 Вкладка «Исправления»: выполняет отмеченные команды после подтверждения,
 с резервной копией настроек в /var/backups/astra-helper.
EOF
mkdir -p dist
OUT="dist/astra-helper_${VER}_all.deb"
dpkg-deb -Zxz --root-owner-group --build "$P" "$OUT" >/dev/null
rm -rf "$B"
echo "Собрано: $OUT"
