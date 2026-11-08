#!/bin/bash
# Сбор зависимостей Astra Linux Helper для установки БЕЗ интернета.
#
# Запускать на машине с ТОЙ ЖЕ версией Astra (и тем же обновлением), что и целевые компьютеры,
# где apt видит репозиторий: интернет, установочный диск или локальный сервер.
#   sudo bash collect-deps.sh
#
# Результат: папка deps/<версия>-<архитектура>/ с .deb (python3-tk, dnsutils и всё, что им нужно),
# самим astra-helper и индексом Packages — её можно нести на флешке или раздать по сети как репозиторий.
set -e
[ "$(id -u)" -ne 0 ] && { echo "Запустите от root:  sudo bash $0"; exit 1; }
cd "$(dirname "$0")"

detect_ver() {
  local s; s="$(head -1 /etc/astra_version 2>/dev/null) $(head -1 /etc/astra/build_version 2>/dev/null)"
  case "$s" in *1.8*) echo 1.8 ;; *1.7*) echo 1.7 ;; *1.6*|*molensk*) echo 1.6 ;; *) echo other ;; esac
}
V=$(detect_ver); ARCH=$(dpkg --print-architecture)
OUT="deps/$V-$ARCH"
mkdir -p "$OUT"
echo "== Astra $V ($ARCH) → $OUT"

echo "== Обновляю список пакетов"
apt-get update -q || echo "!! apt-get update с ошибками — продолжаю с тем, что есть"

WANT=""
for p in python3-tk dnsutils; do
  apt-cache show "$p" >/dev/null 2>&1 && WANT="$WANT $p" || echo "!! Пакета $p нет в репозитории — пропускаю"
done
[ -z "$WANT" ] && { echo "Нечего качать: репозиторий не содержит python3-tk. Проверьте sources.list."; exit 1; }

echo "== Скачиваю$WANT со всеми зависимостями (расчёт как для чистой системы)"
chmod 777 "$OUT"; mkdir -p "$OUT/partial"; chmod 777 "$OUT/partial"
EMPTY=$(mktemp)
# Пустая база dpkg: apt сам выберет нужные версии и альтернативы, как при установке с нуля
apt-get -q -y --no-install-recommends --download-only \
  -o Dir::State::status="$EMPTY" -o Dir::Cache::archives="$(pwd)/$OUT" -o Debug::NoLocking=1 \
  install $WANT
rm -rf "$EMPTY" "$OUT/partial" "$OUT/lock"

# Пакеты с приоритетом required есть на любой установленной Astra — убираем, чтобы не таскать лишнее
for d in "$OUT"/*.deb; do
  case "$(dpkg-deb -f "$d" Priority)" in required) rm -f "$d" ;; esac
done

DEB=$(ls -1 ../dist/astra-helper_*_all.deb astra-helper_*_all.deb 2>/dev/null | sort -V | tail -1)
[ -n "$DEB" ] && cp -f "$DEB" "$OUT/" || echo "!! Не найден astra-helper_*_all.deb — положите его в $OUT вручную"

echo "== Строю индекс Packages (для раздачи по сети)"
( cd "$OUT"
  : > Packages
  for d in *.deb; do
    dpkg-deb -f "$d" >> Packages
    echo "Filename: ./$d" >> Packages
    echo "Size: $(stat -c %s "$d")" >> Packages
    echo "MD5sum: $(md5sum "$d" | cut -d' ' -f1)" >> Packages
    echo "SHA256: $(sha256sum "$d" | cut -d' ' -f1)" >> Packages
    echo >> Packages
  done
  gzip -9c Packages > Packages.gz )
chmod 755 "$OUT"

echo
echo "Готово: $(ls "$OUT"/*.deb | wc -l) пакетов, $(du -sh "$OUT" | cut -f1) в $OUT"
echo "Дальше — один из вариантов:"
echo "  1) флешка: перенесите всю эту папку на компьютер и выполните  sudo bash install-offline.sh"
echo "  2) по сети: здесь запустите  bash serve-lan.sh,  на компьютерах —  sudo bash add-lan-repo.sh <IP_этого_сервера>"
