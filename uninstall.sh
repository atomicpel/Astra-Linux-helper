#!/bin/bash
# Удаление Astra Linux Helper (пакеты python3-tk/dnsutils не трогает)
[ "$(id -u)" -ne 0 ] && { echo "Запустите от root:  sudo bash uninstall.sh"; exit 1; }
rm -f /usr/local/bin/astra-helper /usr/local/bin/astra-fixer /usr/share/applications/astra-helper.desktop /usr/share/applications/astra-fixer.desktop
rm -rf /opt/astra-helper
echo "Astra Linux Helper удалён."
