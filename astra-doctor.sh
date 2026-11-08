#!/bin/bash
# astra-doctor.sh — диагностика типичных проблем Astra Linux SE 1.6 / 1.7 / 1.8
# НИЧЕГО НЕ МЕНЯЕТ в системе: только проверяет и подсказывает, что исправить.
#
# Запуск:  sudo bash astra-doctor.sh [--only sys,apt,sec,gui,net,print,sound,ad] [--domain домен] [--user пользователь]
# Отчёт:   /tmp/astra-doctor-ДАТА.log

ONLY=""; DOMAIN=""; TESTUSER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only)   ONLY="$2";     shift ;;
    --domain) DOMAIN="$2";   shift ;;
    --user)   TESTUSER="$2"; shift ;;
  esac
  shift
done
[ "$(id -u)" -ne 0 ] && { echo "Запустите от root: sudo bash $0"; exit 1; }

export LC_ALL=C LANG=C          # вывод системных команд — на английском, чтобы его разбирать
TTY=0; [ -t 1 ] && TTY=1
LOG="/tmp/astra-doctor-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee "$LOG") 2>&1
if [ $TTY = 1 ]; then R='\e[31m'; G='\e[32m'; Y='\e[33m'; B='\e[1;36m'; N='\e[0m'; else R=; G=; Y=; B=; N=; fi

E=0; W=0; SUM=()
fixout() { [ -n "$1" ] && printf '%b\n' "$1" | sed 's/^/  [FIX] /'; }
ok()     { echo -e "  ${G}[OK]${N} $1"; }
bad()    { echo -e "  ${R}[ОШИБКА]${N} $1"; fixout "$2"; E=$((E+1)); SUM+=("ОШИБКА: $1"); }
warn()   { echo -e "  ${Y}[ВНИМАНИЕ]${N} $1"; fixout "$2"; W=$((W+1)); SUM+=("ВНИМАНИЕ: $1"); }
info()   { echo "     $1"; }
sysi()   { echo "  [SYS] $1"; }
hdr()    { echo; echo -e "${B}== $1 ==${N}"; }
want()   { [ -z "$ONLY" ] || [[ ",$ONLY," == *",$1,"* ]]; }
have()   { command -v "$1" >/dev/null 2>&1; }
port()   { timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null; }
resolve(){ getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}'; }
srv() {
  if have dig; then dig +short SRV "$1" 2>/dev/null | awk '{print $4}'
  elif have host; then host -t SRV "$1" 2>/dev/null | awk '/has SRV/{print $NF}'
  elif have nslookup; then nslookup -type=SRV "$1" 2>/dev/null | awk '/service =/{print $NF}'
  fi | sed 's/\.$//' | sort -u
}
cfg() { # cfg файл ключ — значение ключа из ini-файла
  awk -F= -v k="$2" 'tolower($0) ~ "^[[:space:]]*"k"[[:space:]]*=" {
    v=$0; sub(/^[^=]*=/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; exit}' "$1" 2>/dev/null
}

# =====================================================================
hdr "Система"
VER_RAW=$(head -1 /etc/astra_version 2>/dev/null)
BUILD=$(head -1 /etc/astra/build_version 2>/dev/null)
DEB=$(cat /etc/debian_version 2>/dev/null)
V=""
case "$VER_RAW $BUILD" in
  *1.8*) V=1.8 ;;
  *1.7*) V=1.7 ;;
  *1.6*|*smolensk*|*Smolensk*) V=1.6 ;;
esac
case "$V" in 1.6) EXP_DEB=9 ;; 1.7) EXP_DEB=10 ;; 1.8) EXP_DEB=12 ;; *) EXP_DEB="" ;; esac
sysi "Версия: ${VER_RAW:-не Astra Linux}${BUILD:+ (сборка $BUILD)}"
sysi "База Debian: ${DEB:-?}, ядро: $(uname -r)"
sysi "Компьютер: $(hostname), $(date '+%d.%m.%Y %H:%M')"
VGA=$(lspci 2>/dev/null | grep -iE 'vga|3d controller|display' | head -1 | cut -d: -f3-)
[ -n "$VGA" ] && sysi "Видео:$VGA"
if have astra-modeswitch; then
  m=$(astra-modeswitch get 2>/dev/null)
  case "$m" in 0) mn="Орёл (базовый)" ;; 1) mn="Воронеж (усиленный)" ;; 2) mn="Смоленск (максимальный)" ;; *) mn="$m" ;; esac
  sysi "Уровень защищённости: $mn"
fi
if [ -z "$V" ]; then
  warn "Не удалось определить версию Astra Linux по /etc/astra_version — проверки рассчитаны на Astra 1.6–1.8"
else
  ok "Astra Linux $V"
fi
if [ -n "$EXP_DEB" ] && [[ "$DEB" =~ ^[0-9]+ ]] && [ "${DEB%%.*}" != "$EXP_DEB" ]; then
  warn "База Debian $DEB не соответствует Astra $V (ожидается $EXP_DEB.x) — похоже, ставились пакеты из чужих репозиториев" \
       "Уберите репозитории Debian/Ubuntu из /etc/apt/sources.list и sources.list.d (см. раздел «Пакеты»)\nЕсли система нестабильна — надёжнее переустановка с сохранением /home"
fi

# =====================================================================
if want sys; then
hdr "1. Диск, память, службы, время"
while read -r mp pct; do
  p=${pct%\%}
  if [ "$mp" = "/boot" ]; then fx="Удалите старые ядра (текущее: $(uname -r)):\n  dpkg -l 'linux-image*' | grep ^ii\n  sudo apt-get purge linux-image-<старая_версия>"
  else fx="sudo apt-get clean\nsudo journalctl --vacuum-size=200M\nЧто занимает место:  sudo du -xh --max-depth=2 $mp 2>/dev/null | sort -h | tail -20"; fi
  [ "$mp" = "/home" ] || [ "$mp" = "/" ] && fx="$fx\nЕсли место кончилось в домашнем каталоге — пользователь не сможет войти в графику (чёрный экран или возврат на окно входа)"
  if   [ "$p" -ge 95 ]; then bad "Диск $mp заполнен на $pct" "$fx"
  elif [ "$p" -ge 85 ]; then warn "Диск $mp заполнен на $pct" "$fx"
  else ok "Диск $mp: занято $pct"; fi
done < <(df -P / /boot /var /home /tmp 2>/dev/null | awk 'NR>1{print $6, $5}' | sort -u)
while read -r mp pct; do
  p=${pct%\%}; [ "$p" = "-" ] && continue
  [ "$p" -ge 90 ] && bad "На $mp закончились inode ($pct) — «нет места» при свободных гигабайтах" \
    "Обычно это миллионы мелких файлов. Найти:  sudo du --inodes -x $mp 2>/dev/null | sort -n | tail -15"
done < <(df -Pi / /var /home /tmp 2>/dev/null | awk 'NR>1{print $6, $5}' | sort -u)

if findmnt -no OPTIONS / 2>/dev/null | grep -qE '(^|,)ro(,|$)'; then
  bad "Корневая файловая система смонтирована только для чтения" \
      "Это признак ошибок диска. Загрузитесь в режим восстановления и выполните:\n  fsck -f /dev/<раздел_корня>\nПроверьте состояние диска:  sudo smartctl -a /dev/sda"
else ok "Корневая ФС доступна на запись"; fi

while read -r mp; do
  mountpoint -q "$mp" || warn "Раздел $mp из /etc/fstab не смонтирован" \
    "sudo mount $mp   — посмотрите ошибку\nЕсли это сетевой ресурс, проверьте сеть и учётные данные; для необязательных добавьте в fstab опцию nofail"
done < <(awk '$1!~/^#/ && NF>=4 && $2 ~ /^\// && $3!="swap" && $4!~/noauto/ {print $2}' /etc/fstab 2>/dev/null)

total=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
swap=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
if [ -n "$avail" ] && [ "$avail" -lt 300 ]; then
  warn "Мало свободной памяти: $avail МБ из $total МБ" "Кто занимает память:  ps aux --sort=-%mem | head -15"
else ok "Память: свободно $avail МБ из $total МБ, swap $swap МБ"; fi
[ "${swap:-0}" -eq 0 ] && [ "${total:-0}" -lt 4096 ] && warn "Нет файла/раздела подкачки при ОЗУ меньше 4 ГБ — программы будут закрываться при нехватке памяти" \
  "Создать swap-файл на 2 ГБ:\n  sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile\n  sudo mkswap /swapfile && sudo swapon /swapfile\n  и добавить в /etc/fstab:  /swapfile none swap sw 0 0"

[ -d "/lib/modules/$(uname -r)" ] || bad "Модули текущего ядра $(uname -r) удалены — система обновилась, но не перезагружена (не работают флешки, звук, часть сети)" "Перезагрузите компьютер:  sudo reboot"
[ -f /var/run/reboot-required ] && warn "После обновления требуется перезагрузка" "sudo reboot"

for u in $(systemctl --failed --no-legend 2>/dev/null | grep -oE '[^ ]+\.(service|mount|socket|timer|path|swap|automount)'); do
  warn "Служба $u завершилась с ошибкой" "systemctl status $u\njournalctl -u $u -b --no-pager | tail -30"
done
systemctl --failed --no-legend 2>/dev/null | grep -q . || ok "Все службы systemd работают"

ts=$(timedatectl status 2>/dev/null)
tz=$(echo "$ts" | awk -F': ' '/Time zone/{print $2}')
[ -n "$tz" ] && sysi "Часовой пояс: $tz"
if echo "$ts" | grep -qiE '(NTP synchronized|System clock synchronized): yes'; then
  ok "Время синхронизируется по NTP"
else
  if [ "$V" = 1.6 ]; then
    tfx="Настройте ntp:\n  sudo apt-get install ntp\n  в /etc/ntp.conf оставьте:  server <ваш_сервер_времени> iburst\n  sudo systemctl restart ntp"
  else
    tfx="Включите синхронизацию:  sudo timedatectl set-ntp true\nСервер времени: /etc/systemd/timesyncd.conf (NTP=<сервер>) или /etc/chrony/chrony.conf\nРазово:  sudo ntpdate <сервер>  (если установлен)"
  fi
  warn "Время не синхронизируется по NTP — из-за расхождения ломается вход в домен, сертификаты и сайты" "$tfx"
fi

n=$(journalctl -p 3 -b --no-pager -q 2>/dev/null | wc -l)
if [ "${n:-0}" -gt 0 ]; then
  info "Ошибок в системном журнале с момента загрузки: $n (последние 5):"
  journalctl -p 3 -b --no-pager -q 2>/dev/null | tail -5 | cut -c1-200 | sed 's/^/       /'
fi
fi

# =====================================================================
if want apt; then
hdr "2. Пакеты и репозитории"
if [ -n "$(dpkg --audit 2>/dev/null)" ]; then
  bad "Установка пакетов была прервана — dpkg в неконсистентном состоянии" "sudo dpkg --configure -a\nsudo apt-get -f install"
else ok "Прерванных установок нет"; fi

if have fuser && fuser /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
  warn "База пакетов сейчас занята другим процессом (apt, synaptic или автообновление)" \
       "Дождитесь окончания. Кто держит:  ps aux | grep -E 'apt|dpkg|synaptic'\nНе удаляйте lock-файлы, пока процесс работает"
fi

if out=$(apt-get check -q 2>&1); then ok "Зависимости пакетов в порядке"
else
  bad "Нарушены зависимости пакетов" "sudo apt-get -f install\nПодробности:  sudo apt-get check"
  echo "$out" | tail -3 | sed 's/^/       /'
fi

SRC=$(grep -hE '^[[:space:]]*deb(-src)?[[:space:]]' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null)
SRC822=$(grep -h '^URIs:' /etc/apt/sources.list.d/*.sources 2>/dev/null)
ALLSRC=$(printf '%s\n%s' "$SRC" "$SRC822" | sed '/^$/d')
if [ -z "$ALLSRC" ]; then
  bad "Не подключено ни одного репозитория — apt не может ставить пакеты" \
      "Вставьте установочный диск Astra $V и выполните:  sudo apt-cdrom add\nили пропишите локальный/сетевой репозиторий в /etc/apt/sources.list по инструкции wiki.astralinux.ru для вашей версии и обновления"
else
  info "Подключённые репозитории:"
  echo "$ALLSRC" | sed 's/^/       /'
  if echo "$ALLSRC" | grep -q 'cdrom:'; then
    if [ "$(echo "$ALLSRC" | grep -vc 'cdrom:')" -eq 0 ]; then
      warn "Единственный источник пакетов — диск (cdrom): без вставленного диска установка и обновление падают" \
           "Вставьте диск Astra или смонтируйте ISO и выполните:  sudo apt-cdrom add\nЛибо закомментируйте строку «deb cdrom» и подключите локальный/сетевой репозиторий"
    else
      info "Есть строка cdrom — если диска нет, закомментируйте её, иначе apt будет ругаться"
    fi
  fi
  fr=$(echo "$ALLSRC" | grep -iE 'debian\.org|ubuntu|linuxmint|/debian/|/debian ')
  [ -n "$fr" ] && bad "Подключены репозитории Debian/Ubuntu — главная причина поломок Astra (конфликты версий, слетают fly и средства защиты)" \
    "Закомментируйте (#) в /etc/apt/sources.list(.d) строки:\n$fr\nзатем:  sudo apt-get update"
  case "$V" in
    1.6) wr=$(echo "$ALLSRC" | grep -E '1\.7_|1\.8_|/1\.7/|/1\.8/') ;;
    1.7) wr=$(echo "$ALLSRC" | grep -E '1\.8_|/1\.8/|smolensk/1\.6|/1\.6/') ;;
    1.8) wr=$(echo "$ALLSRC" | grep -E '1\.7_|/1\.7/|/1\.6/|smolensk') ;;
    *)   wr="" ;;
  esac
  [ -n "$wr" ] && bad "Подключён репозиторий от другой версии Astra (у вас $V)" \
    "Замените на репозиторий своей версии или закомментируйте строки:\n$wr"
  echo "$ALLSRC" | grep -qiE 'orel|/common/' && warn "Подключён репозиторий Astra Common Edition (orel) — на SE его смешивать нельзя" \
    "Закомментируйте строки с orel/common в /etc/apt/sources.list(.d)"
  if [ "$V" = 1.6 ] && echo "$ALLSRC" | grep -q 'https://' && ! dpkg -s apt-transport-https >/dev/null 2>&1; then
    bad "Репозиторий по https, а пакет apt-transport-https не установлен (в 1.6 он нужен отдельно) — apt update падает" \
        "Установите с диска:  sudo apt-get install apt-transport-https\nили временно замените https:// на http:// в sources.list"
  fi
fi
ls /var/lib/apt/lists/*Packages >/dev/null 2>&1 || warn "Списки пакетов пусты — apt update не выполнялся или завершался ошибкой" "sudo apt-get update   и посмотрите, какая строка репозитория даёт ошибку"
h=$(apt-mark showhold 2>/dev/null | tr '\n' ' ')
[ -n "$h" ] && info "Заморожены (hold) пакеты: $h"
fi

# =====================================================================
if want sec; then
hdr "3. Средства защиты Astra (частая причина «не запускается», «нет доступа»)"
lock_state() { # 0 — включено, 1 — выключено, 2 — неизвестно
  local o; o=$("$1" status 2>&1); [ -z "$o" ] && o=$("$1" is-enabled 2>&1)
  if echo "$o" | grep -qiE 'usage|Использ|unknown|invalid'; then return 2; fi
  if echo "$o" | grep -qiE 'НЕАКТИВ|неактив|Неактив|ВЫКЛЮЧ|выключ|Выключ|inactive|disabled'; then return 1; fi
  if echo "$o" | grep -qiE 'АКТИВ|актив|Актив|ВКЛЮЧ|включ|Включ|active|enabled'; then return 0; fi
  return 2
}
LOCKS="astra-interpreters-lock|Запрещён запуск интерпретаторов (python, perl и др.) обычным пользователям — их скрипты и часть программ не работают|sudo astra-interpreters-lock disable
astra-bash-lock|Обычным пользователям запрещён bash|sudo astra-bash-lock disable
astra-console-lock|Терминал недоступен пользователям вне группы astra-console|sudo astra-console-lock disable\nили дать доступ одному пользователю:  sudo usermod -aG astra-console ИМЯ
astra-nochmodx-lock|Запрещено делать файлы исполняемыми (chmod +x) — свои скрипты и программы не запустить|sudo astra-nochmodx-lock disable
astra-mount-lock|Пользователям запрещено монтировать носители — флешки и диски не открываются|sudo astra-mount-lock disable
astra-ptrace-lock|Запрещена трассировка процессов — не работают gdb, strace и отладчики|sudo astra-ptrace-lock disable
astra-macros-lock|Запрещены макросы в офисных документах|sudo astra-macros-lock disable
astra-shutdown-lock|Обычным пользователям запрещено выключать и перезагружать компьютер|sudo astra-shutdown-lock disable"
found=0
while IFS='|' read -r tool desc fix; do
  have "$tool" || continue
  found=1
  lock_state "$tool"; st=$?
  case $st in
    0) warn "$desc ($tool включён)" "Если это мешает работе и разрешено политикой ИБ:\n$fix" ;;
    1) ok "$tool выключен" ;;
    *) info "$tool: состояние не определено ($($tool status 2>&1 | head -1))" ;;
  esac
done <<< "$LOCKS"
[ $found = 0 ] && info "Утилиты блокировок astra-*-lock не найдены"

DS=/etc/digsig/digsig_initramfs.conf
if [ -f $DS ]; then
  m=$(grep -E '^[[:space:]]*DIGSIG_ELF_MODE' $DS | cut -d= -f2 | tr -d ' "')
  if [ "$m" = "1" ]; then
    warn "Включена ЗПС (замкнутая программная среда): запускаются только файлы с подписью — сторонние программы и .deb не стартуют («Отказано в доступе», «Operation not permitted»)" \
         "Что заблокировано:  dmesg | grep -i digsig\nСтавьте ПО только из репозиториев Astra или подписанное.\nОтключение (только по решению ИБ):  sudo astra-digsig-control disable  и перезагрузка"
  else ok "ЗПС (контроль подписи, digsig) выключена"; fi
fi
dd=$(dmesg 2>/dev/null | grep -i 'digsig' | grep -iE 'denied|fail|reject|not signed|unsigned' | tail -5)
if [ -n "$dd" ]; then
  warn "ЗПС блокировала запуск файлов (последние записи dmesg)" "Подпишите файл или используйте ПО из репозитория Astra"
  echo "$dd" | cut -c1-200 | sed 's/^/       /'
fi

if have astra-mic-control; then info "МКЦ (мандатный контроль целостности): $(astra-mic-control status 2>&1 | head -1)"
elif [ "$V" = 1.6 ]; then info "В SE 1.6 мандатный контроль целостности и разграничение доступа включены всегда"; fi
if [ -n "$TESTUSER" ] && have pdpl-user; then
  pu=$(pdpl-user "$TESTUSER" 2>&1 | head -3)
  info "Мандатные атрибуты $TESTUSER: $(echo $pu)"
  echo "$pu" | grep -qiE 'not found|не найден|error|ошибк' && warn "У пользователя $TESTUSER не заданы мандатные атрибуты — возможна ошибка входа «Нет доступных мандатных уровней»" \
    "Задать (пример для несекретного уровня):  sudo pdpl-user -l 0:0 $TESTUSER\nПодробно: man pdpl-user"
fi

lk=""; lfx=""
if have faillock; then
  x=$(faillock 2>/dev/null | awk '/^[^ ].*:$/{u=$1; sub(":","",u); next} / V$/{c[u]++} END{for(k in c) if(c[k]>=3) print k"("c[k]")"}')
  [ -n "$x" ] && { lk="$lk $x"; lfx="${lfx}sudo faillock --user ИМЯ --reset\n"; }
fi
if have pam_tally2; then
  x=$(pam_tally2 2>/dev/null | awk 'NR>1 && $2>=3{print $1"("$2")"}')
  [ -n "$x" ] && { lk="$lk $x"; lfx="${lfx}sudo pam_tally2 -r -u ИМЯ\n"; }
fi
if have faillog; then
  x=$(faillog -a 2>/dev/null | awk 'NR>1 && $2+0>=3{print $1"("$2")"}')
  [ -n "$x" ] && { lk="$lk $x"; lfx="${lfx}sudo faillog -r -u ИМЯ\n"; }
fi
if [ -n "$lk" ]; then
  bad "Учётки с неудачными попытками входа (могут быть заблокированы):$(echo $lk | sed 's/^/ /')" "Разблокировать пользователя:\n${lfx%\\n}"
else ok "Блокировок по неудачным попыткам входа нет"; fi
fi

# =====================================================================
if want gui; then
hdr "4. Графика и вход в систему"
dt=$(systemctl get-default 2>/dev/null); info "Цель загрузки: $dt"
if [ "$dt" = "graphical.target" ]; then
  dm=""
  for d in fly-dm lightdm sddm gdm3; do systemctl is-active --quiet "$d" 2>/dev/null && dm=$d; done
  if [ -n "$dm" ]; then ok "Экран входа работает ($dm)"
  else bad "Менеджер входа fly-dm не запущен — вместо окна входа чёрный экран или консоль" \
       "sudo systemctl status fly-dm\njournalctl -u fly-dm -b --no-pager | tail -30\nПерезапуск:  sudo systemctl restart fly-dm"; fi
elif [ "$dt" = "multi-user.target" ]; then
  warn "Система загружается в консоль, без графики" "Вернуть графику:  sudo systemctl set-default graphical.target && sudo reboot"
fi
XL=""
for f in /var/log/Xorg.0.log /var/log/fly-dm/Xorg.0.log; do [ -f "$f" ] && XL=$f && break; done
if [ -n "$XL" ]; then
  ee=$(grep -E '^\[ *[0-9.]+\] \(EE\)' "$XL" | tail -5)
  if echo "$ee" | grep -qi 'no screens found'; then
    bad "Xorg: no screens found — графика не стартует (драйвер видеокарты или xorg.conf)" \
        "Если есть /etc/X11/xorg.conf — переименуйте:  sudo mv /etc/X11/xorg.conf /etc/X11/xorg.conf.bak\nПерезапуск:  sudo systemctl restart fly-dm"
  elif [ -n "$ee" ]; then
    info "Ошибки Xorg в $XL (часто безвредные):"; echo "$ee" | cut -c1-180 | sed 's/^/       /'
  else ok "Ошибок в журнале Xorg нет"; fi
fi
[ -f /etc/X11/xorg.conf ] && warn "Есть ручной /etc/X11/xorg.conf — после замены видеокарты или монитора частая причина чёрного экрана" \
  "sudo mv /etc/X11/xorg.conf /etc/X11/xorg.conf.bak && sudo systemctl restart fly-dm"

while IFS=: read -r u _ uid _ _ home _; do
  [ "$uid" -ge 1000 ] 2>/dev/null && [ "$uid" -lt 60000 ] && [ -d "$home" ] || continue
  own=$(stat -c %U "$home")
  [ "$own" != "$u" ] && bad "Домашний каталог $home принадлежит $own, а не $u — пользователь не сможет войти" "sudo chown -R $u: $home"
  for f in .Xauthority .ICEauthority; do
    [ -e "$home/$f" ] || continue
    fo=$(stat -c %U "$home/$f")
    [ "$fo" != "$u" ] && bad "$home/$f принадлежит $fo — вход в графику будет сбрасываться на окно входа (бывает после запуска программ через sudo из-под пользователя)" \
      "sudo rm $home/$f   (создастся заново при входе)"
  done
done < /etc/passwd
fi

# =====================================================================
if want net; then
hdr "5. Сеть"
gw=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
if [ -z "$gw" ]; then
  bad "Нет шлюза по умолчанию — сеть дальше своей подсети не работает" "Проверьте настройки сети (значок сети → Изменить соединения) или /etc/network/interfaces\nСостояние:  ip addr; ip route"
elif ping -c1 -W2 "$gw" >/dev/null 2>&1; then ok "Шлюз $gw отвечает"
else warn "Шлюз $gw не отвечает на ping (может быть закрыт ICMP)" "Проверьте кабель и подключение:  ip addr;  ip link"; fi

NS=$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null)
if [ -z "$NS" ]; then bad "Не задан ни один DNS-сервер" "Укажите DNS в настройках подключения (значок сети → IPv4 → DNS)"
else
  live=0; for s in $NS; do port "$s" 53 && live=1; done
  [ $live = 1 ] && ok "DNS-сервер отвечает ($(echo $NS))" || bad "Ни один DNS-сервер не отвечает ($(echo $NS)) — имена не резолвятся" "Проверьте адреса DNS в настройках подключения и доступность сервера"
fi

HNs=$(hostname)
if grep -v '^[[:space:]]*#' /etc/hosts | grep -qw "$HNs"; then ok "Имя компьютера $HNs есть в /etc/hosts"
else warn "Имени компьютера $HNs нет в /etc/hosts — sudo долго думает («unable to resolve host»), часть программ сбоит" \
          "Добавьте в /etc/hosts строку:  127.0.1.1  $HNs\n(в домене лучше реальный IP и полное имя:  IP  $HNs.домен  $HNs)"; fi

if systemctl is-active --quiet NetworkManager 2>/dev/null; then
  ifs=$(grep -hE '^[[:space:]]*iface[[:space:]]' /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null | awk '$2!="lo"{print $2}' | sort -u | tr '\n' ' ')
  if [ -n "$ifs" ] && ! grep -qs 'managed=true' /etc/NetworkManager/NetworkManager.conf; then
    warn "Интерфейсы $ifs описаны в /etc/network/interfaces — NetworkManager ими не управляет (значок сети «не управляется», настройки из графики не применяются)" \
         "Выберите один способ настройки:\n- либо удалите их из /etc/network/interfaces (оставьте только lo) и настройте через значок сети;\n- либо оставьте interfaces и не меняйте сеть через значок.\nПосле правки:  sudo systemctl restart networking NetworkManager"
  fi
fi
if port download.astralinux.ru 443; then info "Интернет и сервер обновлений Astra доступны"
else info "Сервер обновлений Astra недоступен (в закрытом контуре это нормально)"; fi
grep -qsiE '^(http|https)_proxy' /etc/environment && info "Задан прокси в /etc/environment: $(grep -iE '^(http|https)_proxy' /etc/environment | head -1)"
fi

# =====================================================================
if want print; then
hdr "6. Печать"
if have lpstat; then
  if systemctl is-active --quiet cups 2>/dev/null; then ok "Служба печати CUPS запущена"
  else bad "Служба печати CUPS не запущена" "sudo systemctl enable cups && sudo systemctl start cups\njournalctl -u cups -b --no-pager | tail -20"; fi
  pr=$(lpstat -p 2>/dev/null)
  if [ -z "$pr" ]; then warn "Принтеры не установлены" "Добавьте через Панель управления → Оборудование → Принтеры или http://localhost:631"
  else
    echo "$pr" | sed 's/^/       /'
    for p in $(echo "$pr" | awk '/disabled/{print $2}'); do
      bad "Принтер $p остановлен (disabled) — задания копятся в очереди" "sudo cupsenable $p\nsudo cupsaccept $p"
    done
  fi
  jobs=$(lpstat -o 2>/dev/null | wc -l)
  [ "$jobs" -gt 0 ] && warn "В очереди печати висит заданий: $jobs" "Посмотреть:  lpstat -o\nОчистить всё:  sudo cancel -a"
  [ -n "$pr" ] && lpstat -d 2>&1 | grep -qi 'no system default' && warn "Не задан принтер по умолчанию" "sudo lpadmin -d ИМЯ_ПРИНТЕРА"
else info "CUPS не установлен — пропуск"; fi
fi

# =====================================================================
if want sound; then
hdr "7. Звук"
if [ ! -f /proc/asound/cards ] || grep -q 'no soundcards' /proc/asound/cards; then
  bad "Звуковые карты не найдены" "Проверьте, включён ли звук в BIOS\nlspci | grep -i audio\ndmesg | grep -iE 'snd|hda'"
else
  ok "Звуковые устройства: $(awk -F' - ' '/^ *[0-9]+ \[/{print $2}' /proc/asound/cards | tr '\n' ';' | sed 's/;$//')"
  info "Если звука нет — проверьте выход (динамики/HDMI) в микшере и что звук не выключен: alsamixer"
fi
fi

# =====================================================================
if want ad; then
hdr "8. Домен (AD / ALD Pro / FreeIPA через SSSD)"
[ -z "$DOMAIN" ] && DOMAIN=$(cfg /etc/sssd/sssd.conf domains | cut -d, -f1 | tr -d ' ')
[ -z "$DOMAIN" ] && have realm && DOMAIN=$(realm list --name-only 2>/dev/null | head -1)
[ -z "$DOMAIN" ] && DOMAIN=$(cfg /etc/samba/smb.conf realm)
have ald-client && info "ALD: $(ald-client status 2>&1 | head -2 | tr '\n' ' ')"
if [ -z "$DOMAIN" ]; then
  info "Компьютер не введён в домен (нет sssd.conf и realm) — пропуск. Для проверки ввода укажите домен в поле «Домен»."
else
DOMAIN=$(echo "$DOMAIN" | tr 'A-Z' 'a-z'); REALM=$(echo "$DOMAIN" | tr 'a-z' 'A-Z')
sysi "Домен: $DOMAIN"
if [ "$V" = 1.6 ]; then JOIN="sudo realm leave $DOMAIN\nsudo realm join -U <админ_домена> --membership-software=samba --client-software=sssd $DOMAIN"
else JOIN="sudo realm leave $DOMAIN\nШтатно для Astra ${V:-1.7+}:  sudo astra-ad-sssd-client -d $DOMAIN -u <админ_домена>\nили:  sudo realm join -U <админ_домена> $DOMAIN"; fi
JOIN="Сначала исправьте DNS, доступность DC и время, затем введите компьютер заново:\n$JOIN\nЕсли в AD осталась старая учётка этого компьютера — удалите её перед вводом"
HN=$(hostname -s); FQDN=$(hostname -f 2>/dev/null)
[ ${#HN} -gt 15 ] && bad "Имя '$HN' длиннее 15 символов — AD обрежет его, учётка компьютера не совпадёт с keytab" "Сократите имя:  sudo hostnamectl set-hostname КОРОТКОЕ_ИМЯ\nпоправьте /etc/hosts и введите компьютер в домен заново"
case "$FQDN" in
  *."$DOMAIN") ok "Полное имя $FQDN в домене" ;;
  *) warn "Полное имя '$FQDN' не заканчивается на .$DOMAIN" "Пропишите в /etc/hosts:  <IP_компьютера>  $HN.$DOMAIN  $HN" ;;
esac
DNSFIX="В настройках сети (значок сети → Изменить соединения → IPv4) укажите DNS = IP живого контроллера домена, поиск = $DOMAIN\nNetworkManager перезаписывает /etc/resolv.conf, поэтому правьте именно там\nПроверка:  host -t SRV _ldap._tcp.$DOMAIN"
for s in $(awk '/^nameserver/{print $2}' /etc/resolv.conf); do
  case $s in 8.8.8.8|8.8.4.4|1.1.1.1|1.0.0.1|77.88.8.8|77.88.8.1)
    bad "DNS $s — внешний, он не знает записей домена" "$DNSFIX" ;; esac
done
ip=$(resolve "$DOMAIN"); [ -n "$ip" ] && ok "$DOMAIN → $ip" || bad "Имя домена $DOMAIN не резолвится — указан не тот DNS" "$DNSFIX"
if ! have dig && ! have host && ! have nslookup; then warn "Нет dig/host/nslookup — SRV-записи не проверить" "sudo apt-get install dnsutils"; fi
DCS=""
for rec in _ldap._tcp _kerberos._tcp _kerberos._udp; do
  r=$(srv "$rec.$DOMAIN")
  if [ -n "$r" ]; then ok "SRV $rec → $(echo $r)"; DCS="$DCS $r"
  else bad "SRV-запись $rec.$DOMAIN не найдена — Kerberos и SSSD не найдут контроллер" "$DNSFIX"; fi
done
DCS=$(echo $DCS | tr ' ' '\n' | sort -u)
DEADFIX="На живом контроллере (Windows Server):\n1) Диспетчер DNS → зоны $DOMAIN и _msdcs.$DOMAIN: удалите A- и SRV-записи упавшего сервера (папки _tcp, _udp, _sites, dc, gc, pdc)\n2) Очистите метаданные: ntdsutil → metadata cleanup (или удалите DC в «AD — пользователи и компьютеры» → Domain Controllers)\n3) Если упавший DC держал роли FSMO — захватите их на новый: ntdsutil → roles → seize"
LIVE_DC=""
for dc in $DCS; do
  ip=$(resolve "$dc")
  [ -z "$ip" ] && { bad "$dc есть в SRV, но не резолвится — мёртвая запись в DNS" "$DEADFIX"; continue; }
  open=""; closed=""
  for p in 53 88 389 445 464; do port "$ip" $p && open="$open $p" || closed="$closed $p"; done
  if [ -z "$open" ]; then bad "Контроллер $dc ($ip) не отвечает ни по одному порту — похоже, упавший DC остался в DNS" "$DEADFIX"
  elif echo " $closed " | grep -qE ' (88|389) '; then bad "$dc ($ip): закрыты ключевые порты$closed" "Откройте на DC и межсетевом экране порты 53, 88, 135, 389, 445, 464, 636, 3268"
  else [ -n "$closed" ] && warn "$dc ($ip): закрыты порты$closed" || ok "Контроллер $dc ($ip) доступен"; [ -z "$LIVE_DC" ] && LIVE_DC=$dc; fi
done
[ -n "$DCS" ] && [ -z "$LIVE_DC" ] && bad "Ни один контроллер домена не доступен" "$DEADFIX"
[ -n "$LIVE_DC" ] && sysi "Живой контроллер: $LIVE_DC"

if [ -n "$LIVE_DC" ]; then
  off=""
  have ntpdate && off=$(ntpdate -q "$LIVE_DC" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="offset"){gsub(/,/,"",$(i+1)); print $(i+1); exit}}')
  if [ -z "$off" ] && have net; then
    st=$(net ads info -S "$LIVE_DC" 2>/dev/null | awk -F': ' '/Server time/{print $2}')
    [ -n "$st" ] && off=$(( $(date -d "$st" +%s 2>/dev/null || date +%s) - $(date +%s) ))
  fi
  if [ -n "$off" ]; then
    a=${off%.*}; a=${a#-}; a=${a:-0}
    TFX="Разово:  sudo ntpdate $LIVE_DC\nПостоянно: укажите $LIVE_DC сервером времени (ntp.conf / timesyncd.conf / chrony.conf)"
    if [ "$a" -gt 300 ]; then bad "Время расходится с $LIVE_DC на $off с (больше 5 минут) — Kerberos отказывает" "$TFX"
    elif [ "$a" -gt 60 ]; then warn "Время расходится с $LIVE_DC на $off с" "$TFX"
    else ok "Время совпадает с $LIVE_DC"; fi
  fi
fi

K=/etc/krb5.conf
if [ -f $K ]; then
  dr=$(cfg $K default_realm)
  [ "$dr" = "$REALM" ] && ok "krb5.conf: default_realm = $dr" || bad "krb5.conf: default_realm = '${dr:-не задан}', должно быть $REALM (ЗАГЛАВНЫМИ)" "В /etc/krb5.conf, секция [libdefaults]:\n  default_realm = $REALM\n  dns_lookup_kdc = true"
  for k in $(awk -F= '/^[[:space:]]*(kdc|admin_server)[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2}' $K | sed 's/:.*//' | sort -u); do
    ip=$(resolve "$k")
    if [ -n "$ip" ] && port "$ip" 88; then ok "krb5.conf: KDC $k отвечает"
    else bad "krb5.conf: прописан недоступный KDC $k — отсюда «Cannot contact any KDC for realm»" "В /etc/krb5.conf замените $k на живой контроллер${LIVE_DC:+ ($LIVE_DC)}\nили удалите строки kdc/admin_server — тогда KDC найдётся через DNS"; fi
  done
else bad "Нет /etc/krb5.conf" "$JOIN"; fi
SSSCLR="sudo systemctl stop sssd\nsudo rm -f /var/lib/sss/db/* /var/lib/sss/mc/* /var/lib/sss/pubconf/kdcinfo.*\nsudo systemctl start sssd"
for f in /var/lib/sss/pubconf/kdcinfo.*; do
  [ -f "$f" ] || continue
  for a in $(cat "$f"); do
    a=${a%%:*}
    port "$a" 88 && ok "Кэш SSSD $(basename "$f"): $a доступен" || bad "Кэш SSSD $(basename "$f") указывает на недоступный KDC $a (старый DC)" "$SSSCLR"
  done
done

S=/etc/sssd/sssd.conf
if [ -f $S ]; then
  perm=$(stat -c '%a %U' $S)
  [ "$perm" = "600 root" ] && ok "Права sssd.conf верные" || bad "Права sssd.conf: $perm — нужно 600 root, иначе sssd не стартует" "sudo chown root:root $S\nsudo chmod 600 $S\nsudo systemctl restart sssd"
  grep -qE "^[[:space:]]*\[domain/$DOMAIN\]" $S || bad "В sssd.conf нет секции [domain/$DOMAIN]" "$JOIN"
  for x in $(for key in ad_server ad_backup_server krb5_server ipa_server ldap_uri; do cfg $S $key; done | tr ',' ' '); do
    x=$(echo "$x" | sed -E 's#ldaps?://##; s#:.*##'); [ "$x" = "_srv_" ] && continue
    ip=$(resolve "$x")
    if [ -n "$ip" ] && port "$ip" 389; then ok "sssd.conf: сервер $x доступен"
    else bad "sssd.conf: прописан недоступный сервер $x" "В $S, секция [domain/$DOMAIN]:\n  ad_server = ${LIVE_DC:-<живой_DC>}   (или _srv_ — искать через DNS)\nзатем очистите кэш:\n$SSSCLR"; fi
  done
else bad "Нет /etc/sssd/sssd.conf" "$JOIN"; fi
if systemctl is-active --quiet sssd 2>/dev/null; then ok "Служба sssd запущена"
else bad "Служба sssd не запущена" "sudo systemctl start sssd\nПричина:  journalctl -u sssd -b --no-pager | tail -30"; fi
if have sssctl; then
  ds=$(sssctl domain-status "$DOMAIN" 2>&1)
  echo "$ds" | grep -qi 'Online status: Offline' && bad "SSSD работает в режиме Offline — не может достучаться до контроллера" "После исправления DNS/KDC:\n$SSSCLR\nПроверка:  sudo sssctl domain-status $DOMAIN"
  echo "$ds" | grep -qi 'Online status: Online' && ok "SSSD в режиме Online"
fi
grep -qE '^passwd:.*sss' /etc/nsswitch.conf && ok "nsswitch использует sss" || bad "В /etc/nsswitch.conf у passwd нет sss — доменные пользователи не видны" "В /etc/nsswitch.conf:\n  passwd: compat sss\n  group:  compat sss\n  shadow: compat sss"
grep -qs pam_sss /etc/pam.d/common-auth && ok "PAM: pam_sss подключён" || bad "В PAM не подключён pam_sss — доменные пользователи не войдут" "sudo pam-auth-update   (отметьте SSS authentication)"

M=/etc/samba/smb.conf
if [ -f $M ]; then
  for x in $(cfg $M "password server" | tr ',' ' '); do
    [ "$x" = "*" ] && continue
    ip=$(resolve "$x")
    [ -n "$ip" ] && port "$ip" 445 && ok "smb.conf: password server $x доступен" || bad "smb.conf: password server = $x недоступен" "В $M, секция [global]:  password server = *"
  done
fi

SAM=$(echo "${HN:0:15}" | tr 'a-z' 'A-Z')
if [ -f /etc/krb5.keytab ]; then
  if klist -k /etc/krb5.keytab 2>/dev/null | grep -qiF "$SAM\$@$REALM"; then
    err=$(KRB5CCNAME=/tmp/adcheck_cc.$$ kinit -k -t /etc/krb5.keytab "$SAM\$@$REALM" 2>&1); rc=$?
    rm -f /tmp/adcheck_cc.$$
    if [ $rc -eq 0 ]; then ok "Учётка компьютера $SAM\$ входит в домен (kinit по keytab)"
    else
      case "$err" in
        *"Cannot contact any KDC"*) bad "Компьютер не может получить билет: Cannot contact any KDC" "Причина в DNS/KDC — см. ошибки выше по DNS, контроллерам, krb5.conf и кэшу SSSD" ;;
        *"not found in Kerberos database"*) bad "Учётки компьютера $SAM\$ нет в AD (удалена)" "$JOIN" ;;
        *"Preauthentication failed"*|*"Password incorrect"*) bad "Пароль компьютера не совпадает с AD (учётку пересоздали или сбросили)" "$JOIN" ;;
        *skew*) bad "Kerberos: расхождение времени с контроллером" "Синхронизируйте время с контроллером домена (см. выше)" ;;
        *) bad "kinit по keytab не прошёл: $(echo $err | cut -c1-150)" "$JOIN" ;;
      esac
    fi
  else bad "В /etc/krb5.keytab нет записи $SAM\$@$REALM — keytab от другого имени или домена" "$JOIN"; fi
else bad "Нет /etc/krb5.keytab — компьютер не введён в домен" "$JOIN"; fi
if [ -n "$TESTUSER" ]; then
  r=$(id "$TESTUSER" 2>&1) && ok "Пользователь найден: $r" || bad "Доменный пользователь $TESTUSER не находится" "После исправлений выше:  sudo sss_cache -E  и снова  id $TESTUSER"
fi
for f in "/var/log/sssd/sssd_$DOMAIN.log" /var/log/sssd/krb5_child.log; do
  [ -f "$f" ] || continue
  l=$(grep -iE 'error|fail|cannot|offline' "$f" | tail -3)
  [ -n "$l" ] && { info "Последние ошибки $f:"; echo "$l" | cut -c1-200 | sed 's/^/       /'; }
done
fi
fi

# =====================================================================
hdr "ИТОГ"
echo "  Ошибок: $E, предупреждений: $W"
for s in "${SUM[@]}"; do echo "  - $s"; done
echo "  Полный отчёт: $LOG"
