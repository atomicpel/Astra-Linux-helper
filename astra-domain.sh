#!/bin/bash
# astra-domain.sh — ввод Astra Linux SE в домен Active Directory с выбором контроллера.
#
#   scan     --domain D
#            найти контроллеры домена, проверить доступность, отклик и сайт AD (ничего не меняет)
#   precheck --domain D --dc DC[,DC2] [--user U --passfile F] [--ou OU]
#            проверка перед вводом в домен: что именно помешает (ничего не меняет)
#   join     --domain D --dc DC[,DC2] --user U --passfile F [--ou OU] [--srv]
#            ввод в домен через adcli + настройка SSSD (копия настроек — /var/backups/astra-helper)
#   wizard   [--domain D]
#            всё по шагам в терминале
#
# Пароль доменного пользователя передаётся файлом (--passfile), файл сразу удаляется.

MODE="$1"; shift
DOMAIN=""; DCLIST=""; DUSER=""; PASSFILE=""; OU=""; USE_SRV=0
while [ $# -gt 0 ]; do
  case "$1" in
    --domain)   DOMAIN="$2";   shift ;;
    --dc)       DCLIST="$2";   shift ;;
    --user)     DUSER="$2";    shift ;;
    --passfile) PASSFILE="$2"; shift ;;
    --ou)       OU="$2";       shift ;;
    --srv)      USE_SRV=1 ;;
  esac
  shift
done
[ "$(id -u)" -ne 0 ] && { echo "Запустите от root: sudo bash $0 $MODE ..."; exit 1; }
export LC_ALL=C LANG=C

E=0; W=0
fixout() { [ -n "$1" ] && printf '%b\n' "$1" | sed 's/^/  [FIX] /'; }
ok()     { echo "  [OK] $1"; }
bad()    { echo "  [ОШИБКА] $1"; fixout "$2"; E=$((E+1)); }
warn()   { echo "  [ВНИМАНИЕ] $1"; fixout "$2"; W=$((W+1)); }
info()   { echo "     $1"; }
hdr()    { echo; echo "== $1 =="; }
have()   { command -v "$1" >/dev/null 2>&1; }
port()   { timeout "${3:-2}" bash -c "</dev/tcp/$1/$2" 2>/dev/null; }
resolve(){ getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}'; }
pkg_ok() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
srv() {
  if have dig; then dig +short SRV "$1" 2>/dev/null | awk '{print $4}'
  elif have host; then host -t SRV "$1" 2>/dev/null | awk '/has SRV/{print $NF}'
  elif have nslookup; then nslookup -type=SRV "$1" 2>/dev/null | awk '/service =/{print $NF}'
  fi | sed 's/\.$//' | tr 'A-Z' 'a-z' | sort -u
}
cfg() { awk -F= -v k="$2" 'tolower($0) ~ "^[[:space:]]*"k"[[:space:]]*=" {
    v=$0; sub(/^[^=]*=/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; exit}' "$1" 2>/dev/null; }

DOMAIN=$(echo "$DOMAIN" | tr 'A-Z' 'a-z'); REALM=$(echo "$DOMAIN" | tr 'a-z' 'A-Z')
DUSER=${DUSER##*\\}; DUSER=${DUSER%%@*}                 # DOMAIN\user и user@domain → user
HN=$(hostname -s 2>/dev/null); SAM=$(echo "${HN:0:15}" | tr 'a-z' 'A-Z')
VER=$(head -1 /etc/astra_version 2>/dev/null)
PKGS="adcli sssd libnss-sss libpam-sss krb5-user sssd-tools"

krb_hint() { # расшифровка ошибок Kerberos
  case "$1" in
    *"Preauthentication failed"*|*"Password incorrect"*) echo "неверный пароль пользователя $2" ;;
    *"not found in Kerberos database"*) echo "пользователя $2 нет в домене (нужен логин без домена, например ivanov)" ;;
    *"redentials have been revoked"*) echo "учётка $2 заблокирована или отключена (часто после нескольких неверных паролей)" ;;
    *"assword has expired"*) echo "срок действия пароля $2 истёк — смените его на уже работающем компьютере" ;;
    *"Clock skew"*) echo "время на компьютере расходится с контроллером больше чем на 5 минут" ;;
    *"Cannot contact any KDC"*|*"Cannot find KDC"*|*"Cannot resolve"*) echo "контроллер не отвечает по Kerberos (порт 88)" ;;
    *"no support for encryption type"*) echo "контроллер не принимает типы шифрования этого компьютера — вопрос к администраторам домена" ;;
    *) echo "" ;;
  esac
}

# probe IP порт… → "отклик_мс|закрытые порты". Замер внутри python3 точнее (без накладных расходов на запуск процессов).
probe() {
  if have python3; then
    python3 -c '
import socket, sys, time
ip = sys.argv[1]; best = None; closed = []
for n, p in enumerate(sys.argv[2:]):
    ok = False
    for i in range(3 if n == 0 else 1):
        s = socket.socket(); s.settimeout(2 if (best is not None or n < 2) else 1); t = time.time()
        try:
            s.connect((ip, int(p))); d = (time.time() - t) * 1000.0; ok = True
            if best is None or d < best: best = d
        except Exception:
            pass
        finally:
            s.close()
        if not ok: break
    if not ok: closed.append(p)
    if n == 2 and best is None:
        closed = list(sys.argv[2:]); break
print("%s|%s" % ("" if best is None else max(1, int(round(best))), " ".join(closed)))
' "$@" 2>/dev/null && return
  fi
  local ip="$1" ms="" closed="" p t0 d; shift
  for p in "$@"; do
    t0=$(date +%s%N)
    if port "$ip" "$p"; then d=$(( ($(date +%s%N) - t0) / 1000000 )); { [ -z "$ms" ] || [ "$d" -lt "$ms" ]; } && ms=$d
    else closed="$closed $p"; fi
  done
  echo "$ms|${closed# }"
}

# ---------------------------------------------------------------- scan
dc_site() { # → "сайт_контроллера|сайт_клиента|короткое_имя_домена"
  local o
  if have adcli; then
    o=$(timeout 6 adcli info --domain-controller="$1" 2>/dev/null)
    [ -n "$o" ] && { echo "$(echo "$o" | awk -F' = ' '/^domain-controller-site/{print $2}')|$(echo "$o" | awk -F' = ' '/^computer-site/{print $2}')|$(echo "$o" | awk -F' = ' '/^domain-short/{print $2}')"; return; }
  fi
  if have net; then
    o=$(timeout 6 net ads lookup -S "$1" 2>/dev/null)
    [ -n "$o" ] && { echo "$(echo "$o" | awk -F': *' '/Server Site Name/{print $2}')|$(echo "$o" | awk -F': *' '/Client Site Name/{print $2}')|$(echo "$o" | awk -F': *' '/Pre-Win2k Domain/{print $2}')"; return; }
  fi
  echo "||"
}
scan_one() {
  local dc="$1" ip r ms closed st site flags=""
  ip=$(resolve "$dc")
  [ -z "$ip" ] && { echo "[DC] $dc||nodns||||||"; return; }
  r=$(probe "$ip" 389 88 445 464 53); ms=${r%%|*}; closed=${r#*|}
  if [ -z "$ms" ]; then st=dead
  elif echo " $closed " | grep -qE ' (389|88|464) '; then st=partial
  else st=ok; fi
  site="||"; [ "$st" != dead ] && site=$(dc_site "$dc")
  case "$NSLIST" in *" $ip "*) flags="dns" ;; esac
  case "$CFGLIST" in *" $dc "*|*" $ip "*) flags="$flags cfg" ;; esac
  echo "[DC] $dc|$ip|$st|$ms|$closed|$site|${flags# }"
}
do_scan() {
  [ -z "$DOMAIN" ] && { bad "Не указан домен"; return 2; }
  local names tmp n=0 dc
  names=$( { srv "_ldap._tcp.dc._msdcs.$DOMAIN"; srv "_ldap._tcp.$DOMAIN"; srv "_kerberos._tcp.$DOMAIN"; } | sort -u)
  if [ -z "$names" ]; then
    if ! have dig && ! have host && ! have nslookup; then
      bad "Нет утилит dig/host/nslookup — не могу найти контроллеры" "sudo apt-get install dnsutils"
    else
      bad "В DNS нет SRV-записей домена $DOMAIN — контроллеры не найдены" "Проверьте имя домена и DNS-сервер в настройках сети: DNS должен быть контроллером домена\nСейчас DNS: $(awk '/^nameserver/{print $2}' /etc/resolv.conf | tr '\n' ' ')"
    fi
    return 1
  fi
  NSLIST=" $(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
  CFGLIST=" $( { for k in ad_server ad_backup_server; do cfg /etc/sssd/sssd.conf $k; done
                 awk -F= '/^[[:space:]]*(kdc|admin_server)[[:space:]]*=/{print $2}' /etc/krb5.conf 2>/dev/null; } \
               | tr ',' '\n' | sed 's/[[:space:]]//g; s/:.*//' | tr 'A-Z' 'a-z' | tr '\n' ' ') "
  tmp=$(mktemp -d)
  for dc in $names; do
    scan_one "$dc" > "$tmp/$dc" &
    n=$((n+1)); [ $((n % 24)) -eq 0 ] && wait
  done
  wait
  cat "$tmp"/*
  echo "[SITE] $(cat "$tmp"/* | awk -F'|' '$7!=""{c[$7]++} END{m=0; s=""; for(k in c) if(c[k]>m){m=c[k]; s=k} print s}')"
  echo "[SHORT] $(cat "$tmp"/* | awk -F'|' '$8!=""{print $8; exit}')"
  echo "[SCAN] $n|$(cat "$tmp"/* | grep -c '|ok|')|$(cat "$tmp"/* | grep -c '|partial|')|$(cat "$tmp"/* | grep -cE '\|(dead|nodns)\|')"
  rm -rf "$tmp"
}

# ---------------------------------------------------------------- общая подготовка
read_pass() { PASS=""; [ -n "$PASSFILE" ] && [ -f "$PASSFILE" ] && { PASS=$(head -1 "$PASSFILE"); rm -f "$PASSFILE"; }; }
make_krb_conf() { # временный krb5.conf, привязанный к выбранному контроллеру
  KC=$(mktemp /tmp/astra-krb5.XXXXXX); CC=$(mktemp /tmp/astra-cc.XXXXXX)
  cat > "$KC" <<EOF
[libdefaults]
  default_realm = $REALM
  dns_lookup_kdc = false
  dns_lookup_realm = false
  rdns = false
[realms]
  $REALM = {
    kdc = $DC1
    kpasswd_server = $DC1
  }
[domain_realm]
  .$DOMAIN = $REALM
  $DOMAIN = $REALM
EOF
}
cleanup() { [ -n "$KC" ] && rm -f "$KC"; [ -n "$CC" ] && rm -f "$CC"; [ -n "$PASSFILE" ] && rm -f "$PASSFILE"; }
trap cleanup EXIT
need_args() {
  [ -z "$DOMAIN" ] && { bad "Не указан домен"; return 1; }
  [ -z "$DCLIST" ] && { bad "Не выбран контроллер домена" "Сначала «Найти контроллеры», затем отметьте ближайший"; return 1; }
  DCS=$(echo "$DCLIST" | tr ',' ' ' | tr 'A-Z' 'a-z'); DC1=${DCS%% *}
  return 0
}

# ---------------------------------------------------------------- precheck
do_precheck() {
  need_args || return 2
  read_pass
  echo "Проверка перед вводом в домен $DOMAIN — контроллер $DC1 — $(date '+%d.%m.%Y %H:%M')"
  echo "Компьютер: $HN (учётка в AD будет $SAM\$), ${VER:-версия Astra не определена}"

  hdr "1. Пакеты"
  if [ -n "$(dpkg --audit 2>/dev/null)" ]; then
    bad "Прошлая установка пакетов прервана — новые пакеты не поставятся" "sudo dpkg --configure -a && sudo apt-get -f install\n(кнопка «Ввести в домен» сделает это сама)"
  else ok "База пакетов в порядке"; fi
  miss=""; nocand=""
  for p in $PKGS; do
    pkg_ok "$p" && continue
    miss="$miss $p"
    apt-cache policy "$p" 2>/dev/null | grep -q 'Candidate: [0-9a-zA-Z]' || nocand="$nocand $p"
  done
  if [ -z "$miss" ]; then ok "Нужные пакеты установлены: $PKGS"
  elif [ -n "$nocand" ]; then
    bad "Не установлены и не найдены в репозитории:$nocand" "Подключите репозиторий или диск Astra (sudo apt-cdrom add; sudo apt-get update) и повторите\nНужны пакеты: $PKGS"
  else warn "Не установлены:$miss — в репозитории они есть, поставятся при вводе в домен" "Вручную: sudo apt-get install -y$miss"; fi

  hdr "2. Имя компьютера"
  FQDN=$(hostname -f 2>/dev/null)
  if [ ${#HN} -gt 15 ]; then bad "Имя '$HN' длиннее 15 символов — в AD оно обрежется до $SAM и вход работать не будет" "sudo hostnamectl set-hostname КОРОТКОЕ_ИМЯ  и поправьте /etc/hosts"
  else ok "Имя $HN подходит (не длиннее 15 символов)"; fi
  case "$FQDN" in
    "$HN.$DOMAIN"|*".$DOMAIN") ok "Полное имя: $FQDN" ;;
    *) warn "Полное имя '$FQDN' не в домене $DOMAIN — при вводе будет использовано $HN.$DOMAIN" "Правильно прописать в /etc/hosts:  <IP_компьютера>  $HN.$DOMAIN  $HN" ;;
  esac

  hdr "3. DNS"
  NS=$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')
  DNSFIX="В настройках сети (значок сети → Изменить соединения → IPv4) укажите DNS = IP контроллера домена и домен поиска $DOMAIN"
  if [ -z "$NS" ]; then bad "Не задан DNS-сервер" "$DNSFIX"; else ok "DNS-серверы: $NS"; fi
  ip=$(resolve "$DOMAIN"); [ -n "$ip" ] && ok "Имя домена $DOMAIN резолвится" || bad "Имя домена $DOMAIN не резолвится — DNS не знает домен" "$DNSFIX"
  r=$(srv "_ldap._tcp.$DOMAIN" | wc -l)
  [ "$r" -gt 0 ] && ok "SRV-записи домена есть (контроллеров в DNS: $r)" || bad "В DNS нет SRV-записей _ldap._tcp.$DOMAIN" "$DNSFIX"

  hdr "4. Выбранные контроллеры"
  for dc in $DCS; do
    ip=$(resolve "$dc")
    if [ -z "$ip" ]; then bad "$dc не резолвится в IP" "Выберите другой контроллер из списка"; continue; fi
    r=$(probe "$ip" 389 88 464 445 53 636 3268); ms=${r%%|*}; closed=" ${r#*|}"; [ "$closed" = " " ] && closed=""
    if echo " $closed " | grep -qE ' (88|389|464) '; then
      bad "$dc ($ip): закрыты нужные для ввода порты:$(echo " $closed " | grep -oE ' (88|389|464)' | tr -d '\n')" "88 — Kerberos, 389 — LDAP, 464 — смена пароля учётки компьютера\nВыберите другой контроллер или попросите открыть порты на межсетевом экране"
    elif [ -n "$closed" ]; then warn "$dc ($ip): отклик $ms мс, закрыты второстепенные порты:$closed (для ввода через adcli не нужны)"
    else ok "$dc ($ip): все порты открыты, отклик $ms мс"; fi
    [ -n "$ms" ] && [ "$ms" -gt 150 ] && warn "$dc отвечает медленно ($ms мс) — похоже, он далеко; вход в систему будет тормозить" "Выберите контроллер с меньшим откликом или из вашего сайта AD"
  done
  s=$(dc_site "$DC1"); dsite=${s%%|*}; rest=${s#*|}; csite=${rest%%|*}; SHORT=${rest#*|}
  [ -n "$dsite" ] && info "Сайт AD контроллера: $dsite; сайт этого компьютера: ${csite:-не определён (подсеть не привязана к сайту)}"
  [ -n "$csite" ] && [ -n "$dsite" ] && [ "$csite" != "$dsite" ] && warn "Контроллер $DC1 из чужого сайта AD ($dsite), ваш сайт — $csite" "В списке контроллеров выберите помеченный «ваш сайт AD»"

  hdr "5. Время"
  off=""
  have ntpdate && off=$(timeout 8 ntpdate -q "$DC1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="offset"){gsub(/,/,"",$(i+1)); print $(i+1); exit}}')
  if [ -z "$off" ] && have ldapsearch; then
    ct=$(timeout 6 ldapsearch -x -LLL -H "ldap://$DC1" -s base -b "" currentTime 2>/dev/null | awk '/^currentTime:/{print $2}')
    [ -n "$ct" ] && off=$(( $(date -u -d "${ct:0:4}-${ct:4:2}-${ct:6:2} ${ct:8:2}:${ct:10:2}:${ct:12:2}" +%s 2>/dev/null || date +%s) - $(date -u +%s) ))
  fi
  if [ -n "$off" ]; then
    a=${off%.*}; a=${a#-}; a=${a:-0}
    if [ "$a" -gt 300 ]; then bad "Время расходится с $DC1 на $off с — Kerberos откажет (допустимо до 5 минут)" "sudo ntpdate $DC1   (или настройте $DC1 сервером времени)"
    elif [ "$a" -gt 60 ]; then warn "Время расходится с $DC1 на $off с" "sudo ntpdate $DC1"
    else ok "Время совпадает с контроллером (разница $off с)"; fi
  else info "Разницу времени измерить нечем (нет ntpdate/ldapsearch) — она проверится при проверке пароля. Сейчас: $(date)"; fi

  hdr "6. Kerberos и SMB"
  if [ -f /etc/krb5.conf ]; then
    dr=$(cfg /etc/krb5.conf default_realm)
    [ "$dr" = "$REALM" ] && ok "krb5.conf: default_realm = $REALM" || warn "krb5.conf: default_realm = '${dr:-не задан}' — при вводе будет исправлено на $REALM"
    for k in $(awk -F= '/^[[:space:]]*(kdc|admin_server)[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2}' /etc/krb5.conf | sed 's/:.*//' | sort -u); do
      kip=$(resolve "$k")
      { [ -n "$kip" ] && port "$kip" 88; } || warn "krb5.conf: прописан недоступный KDC $k" "Уберите строки kdc/admin_server с $k из /etc/krb5.conf — KDC найдётся через DNS"
    done
  else warn "Нет /etc/krb5.conf — будет создан при вводе"; fi
  if have smbclient; then
    o3=$(timeout 10 smbclient -N -L "$DC1" -m SMB3 2>&1 | head -5)
    o1=$(timeout 10 smbclient -N -L "$DC1" 2>&1 | head -5)
    if echo "$o1" | grep -qiE 'CONNECTION_RESET|negotiation failed|CONNECTION_DISCONNECTED'; then
      if echo "$o3" | grep -qiE 'CONNECTION_RESET|negotiation failed|CONNECTION_DISCONNECTED'; then
        warn "$DC1 рвёт SMB-соединение (NT_STATUS_CONNECTION_RESET) даже по SMB3 — ввод способом samba (realm join/net ads join) с ним не пройдёт" "Эта программа вводит через adcli (LDAP+Kerberos), SMB ей не нужен"
      else
        warn "$DC1 не принимает старый протокол SMB1, а Samba на этом компьютере начинает с него — отсюда «Protocol negotiation failed: NT_STATUS_CONNECTION_RESET» при realm join" "Эта программа вводит через adcli, SMB ей не нужен.\nДля самой Samba: в /etc/samba/smb.conf, секция [global]:  client max protocol = SMB3"
      fi
    else ok "SMB-соединение с $DC1 устанавливается"; fi
  else info "smbclient не установлен — проверка SMB пропущена (для ввода через adcli SMB не нужен)"; fi

  hdr "7. Логин и пароль администратора домена"
  KRBOK=0
  if [ -z "$DUSER" ]; then warn "Не указан пользователь домена — логин и пароль не проверены" "Заполните поле «Администратор домена» и повторите проверку"
  elif [ -z "$PASS" ]; then warn "Пароль не введён — логин и пароль не проверены" "Повторите проверку и введите пароль: программа скажет, пускает ли контроллер этого пользователя"
  elif ! have kinit; then warn "Нет kinit (пакет krb5-user) — пароль проверить нечем, поставится при вводе"
  else
    make_krb_conf
    err=$(printf '%s\n' "$PASS" | KRB5_CONFIG="$KC" KRB5CCNAME="FILE:$CC" timeout 25 kinit "$DUSER@$REALM" 2>&1); rc=$?
    if [ $rc -eq 0 ]; then ok "Контроллер $DC1 принял логин и пароль $DUSER"; KRBOK=1
    else
      h=$(krb_hint "$err" "$DUSER")
      bad "Контроллер не принял $DUSER: ${h:-$(echo "$err" | grep -v '^Password for' | tail -1 | cut -c1-200)}" "Ответ Kerberos: $(echo "$err" | grep -v '^Password for' | tail -1 | cut -c1-200)\nПока это не исправлено, ввод в домен не пройдёт («The attempted logon is invalid»)"
    fi
  fi

  hdr "8. Учётная запись компьютера и остатки прошлого ввода"
  if [ "$KRBOK" = 1 ]; then
    found=""
    if have ldapsearch; then
      base="DC=$(echo "$DOMAIN" | sed 's/\./,DC=/g')"
      o=$(KRB5_CONFIG="$KC" KRB5CCNAME="FILE:$CC" timeout 15 ldapsearch -Q -Y GSSAPI -LLL -H "ldap://$DC1" -b "$base" "(sAMAccountName=$SAM\$)" dn 2>/dev/null | awk '/^dn:/{sub(/^dn: */,""); print; exit}')
      [ -n "$o" ] && found="$o"; [ -z "$o" ] && found="-"
    fi
    if [ -z "$found" ] && adcli show-computer --help >/dev/null 2>&1; then
      o=$(KRB5_CONFIG="$KC" timeout 15 adcli show-computer -D "$DOMAIN" -S "$DC1" --login-ccache="$CC" 2>/dev/null | awk -F' = ' '/^dn|distinguishedName/{print $2; exit}')
      [ -n "$o" ] && found="$o" || found="-"
    fi
    if [ -z "$found" ]; then info "Наличие учётки $SAM\$ в AD проверить нечем (нет ldap-utils) — не критично"
    elif [ "$found" = "-" ]; then ok "Учётки компьютера $SAM\$ в AD ещё нет — будет создана"
    else warn "В AD уже есть учётка компьютера: $found" "При вводе она будет использована повторно. Если ввод ответит «Insufficient permissions» — у $DUSER нет прав на эту учётку:\nпопросите администратора домена удалить её или выдать права"; fi
  else info "Учётка компьютера в AD не проверялась (нужны логин и пароль)"; fi
  if [ -n "$OU" ]; then
    echo "$OU" | grep -qiE '^(OU|CN)=.+,DC=' && ok "OU для учётки компьютера: $OU" || bad "OU записан неверно: $OU" "Нужен полный путь, например:  OU=Computers,OU=Kerch,DC=$(echo "$DOMAIN" | sed 's/\./,DC=/g')"
  else info "OU не указан — учётка компьютера создаётся в контейнере по умолчанию (Computers)"; fi
  [ -f /etc/krb5.keytab ] && info "Есть старый /etc/krb5.keytab — при вводе будет сохранён в копию и заменён"
  if [ -f /etc/sssd/sssd.conf ]; then
    grep -qE "^[[:space:]]*\[domain/$DOMAIN\]" /etc/sssd/sssd.conf \
      && info "В sssd.conf уже есть секция домена — настройки сохранятся, заменится только список контроллеров" \
      || info "В sssd.conf нет секции домена (остаток неудачного ввода) — файл будет сохранён в копию и создан заново"
  fi
  grep -qs pam_sss /etc/pam.d/common-auth || info "pam_sss в PAM пока не подключён — подключится при вводе"
  grep -qs pam_mkhomedir /etc/pam.d/common-session || info "Создание домашних каталогов (pam_mkhomedir) пока не настроено — настроится при вводе"

  hdr "ИТОГ"
  if [ $E -eq 0 ]; then echo "  [OK] Препятствий для ввода в домен не найдено (предупреждений: $W). Можно нажимать «Ввести в домен»."
  else echo "  [ОШИБКА] Найдено препятствий: $E (предупреждений: $W). Исправьте ошибки выше — иначе ввод в домен не пройдёт."; fi
  echo "[RESULT] precheck $E $W"
}

# ---------------------------------------------------------------- join
step() { echo; echo "== Шаг $1 =="; }
fail() { echo "  [ОШИБКА] $1"; fixout "$2"; [ -n "$KT_MOVED" ] && [ ! -f /etc/krb5.keytab ] && cp -p "$BK/krb5.keytab" /etc/krb5.keytab 2>/dev/null; echo "[RESULT] join fail"; exit 1; }
do_join() {
  need_args || { echo "[RESULT] join fail"; return 2; }
  read_pass
  [ -z "$DUSER" ] && fail "Не указан администратор домена"
  [ -z "$PASS" ] && fail "Не введён пароль"
  echo "Ввод в домен $DOMAIN через контроллер $DC1 — $(date '+%d.%m.%Y %H:%M')"

  step "1. Резервная копия настроек"
  BK=/var/backups/astra-helper/$(date +%Y%m%d-%H%M%S)-join; mkdir -p "$BK"
  tar czf "$BK/etc-backup.tgz" --ignore-failed-read /etc/krb5.conf /etc/krb5.keytab /etc/sssd /etc/samba/smb.conf \
      /etc/nsswitch.conf /etc/hosts /etc/pam.d 2>/dev/null
  chmod 600 "$BK/etc-backup.tgz"
  ok "Сохранено: $BK/etc-backup.tgz"

  step "2. Пакеты"
  if [ -n "$(dpkg --audit 2>/dev/null)" ]; then info "Завершаю прерванную установку пакетов…"; DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>&1 | tail -5 | sed 's/^/       /'; fi
  miss=""; for p in $PKGS; do pkg_ok "$p" || miss="$miss $p"; done
  if [ -n "$miss" ]; then
    info "Устанавливаю:$miss"
    DEBIAN_FRONTEND=noninteractive apt-get install -y $miss 2>&1 | tail -6 | sed 's/^/       /'
  fi
  for p in adcli sssd libnss-sss libpam-sss; do
    pkg_ok "$p" || have "$p" || fail "Пакет $p не установился" "Подключите репозиторий или диск Astra:  sudo apt-cdrom add; sudo apt-get update;  sudo apt-get install $PKGS"
  done
  ok "Пакеты на месте"

  step "3. Ввод в домен (adcli join)"
  FQDN="$HN.$DOMAIN"
  ARGS=(join --verbose -D "$DOMAIN" -S "$DC1" -U "$DUSER" --stdin-password --host-fqdn="$FQDN")
  [ -n "$OU" ] && ARGS+=(--domain-ou="$OU")
  adcli join --help 2>&1 | grep -q -- '--os-name' && ARGS+=(--os-name="Astra Linux SE" --os-version="${VER:-unknown}")
  if [ -f /etc/krb5.keytab ]; then cp -p /etc/krb5.keytab "$BK/krb5.keytab"; rm -f /etc/krb5.keytab; KT_MOVED=1; fi
  out=$(printf '%s' "$PASS" | timeout 180 adcli "${ARGS[@]}" 2>&1); rc=$?
  echo "$out" | grep -v '^$' | sed 's/^/       /'
  if [ $rc -ne 0 ] || [ ! -s /etc/krb5.keytab ]; then
    h=$(krb_hint "$out" "$DUSER"); fx=""
    if [ -z "$h" ]; then
      case "$out" in
        *nsufficient*|*"Couldn't create computer account"*|*"Couldn't set password"*|*"Cannot set computer password"*|*"Access denied"*|*"access denied"*)
          h="у $DUSER нет прав создать или изменить учётку компьютера $SAM\$"
          fx="В AD уже может быть учётка $SAM\$, созданная другим администратором, или у $DUSER нет прав на этот OU.\nПопросите администратора домена удалить старую учётку $SAM\$ либо выдать права, или укажите свой OU в поле «OU»." ;;
        *"No such object"*) h="OU не найден в домене"; fx="Проверьте поле «OU»: $OU" ;;
        *"Can't contact LDAP"*|*"Couldn't connect"*|*"Couldn't discover"*|*"imed out"*) h="контроллер $DC1 не отвечает"; fx="Выберите другой контроллер и повторите проверку перед вводом" ;;
        *"Server not found in Kerberos database"*) h="в домене нет служебной записи (SPN) для $DC1"; fx="Выберите другой контроллер" ;;
        *) h="adcli завершился с кодом $rc" ; fx="Текст ошибки — в журнале выше; скопируйте его целиком" ;;
      esac
    fi
    fail "Ввод в домен не прошёл: $h" "$fx"
  fi
  ok "Компьютер введён в домен, создан /etc/krb5.keytab"

  step "4. Настройка Kerberos и SSSD"
  K=/etc/krb5.conf
  if [ ! -f $K ]; then
    printf '[libdefaults]\n  default_realm = %s\n  dns_lookup_kdc = true\n  dns_lookup_realm = false\n  rdns = false\n\n[domain_realm]\n  .%s = %s\n  %s = %s\n' "$REALM" "$DOMAIN" "$REALM" "$DOMAIN" "$REALM" > $K
    ok "Создан $K"
  elif [ "$(cfg $K default_realm)" != "$REALM" ]; then
    if grep -qE '^[[:space:]]*default_realm[[:space:]]*=' $K; then sed -i -E "s/^([[:space:]]*default_realm[[:space:]]*=).*/\\1 $REALM/" $K
    elif grep -q '^\[libdefaults\]' $K; then sed -i "/^\[libdefaults\]/a\\  default_realm = $REALM" $K
    else printf '\n[libdefaults]\n  default_realm = %s\n' "$REALM" >> $K; fi
    ok "В $K исправлен default_realm = $REALM"
  fi
  s=$(dc_site "$DC1"); rest=${s#*|}; SHORT=${rest#*|}
  [ -z "$SHORT" ] && SHORT=$(echo "${DOMAIN%%.*}" | tr 'a-z' 'A-Z')
  SERVERS=$(echo $DCS | sed 's/ /, /g'); [ "$USE_SRV" = 1 ] && SERVERS="$SERVERS, _srv_"
  S=/etc/sssd/sssd.conf; mkdir -p /etc/sssd
  systemctl stop sssd 2>/dev/null
  if [ -f $S ] && grep -qE "^[[:space:]]*\[domain/$DOMAIN\]" $S; then
    awk -v sec="[domain/$DOMAIN]" -v line="ad_server = $SERVERS" '
      /^[[:space:]]*\[/ { insec = ($0 ~ /^[[:space:]]*\[domain\//) && (index($0, sec) > 0); print; if (insec) print line; next }
      insec && /^[[:space:]]*(ad_server|ad_backup_server)[[:space:]]*=/ { next }
      { print }' $S > $S.new && mv $S.new $S
    ok "В существующем sssd.conf заменён список контроллеров: $SERVERS"
  else
    cat > $S <<EOF
[sssd]
domains = $DOMAIN
config_file_version = 2
services = nss, pam

[domain/$DOMAIN]
ad_domain = $DOMAIN
krb5_realm = $REALM
ad_server = $SERVERS
ad_hostname = $FQDN
realmd_tags = manages-system joined-with-adcli
id_provider = ad
access_provider = ad
ad_gpo_access_control = disabled
ad_gpo_map_interactive = +fly-dm
cache_credentials = True
krb5_store_password_if_offline = True
ldap_id_mapping = True
use_fully_qualified_names = False
fallback_homedir = /home/$SHORT/%u
default_shell = /bin/bash
krb5_ccname_template = FILE:%d/krb5cc_%U
EOF
    mkdir -p "/home/$SHORT"; chmod 755 "/home/$SHORT"
    ok "Создан sssd.conf: контроллеры $SERVERS, домашние каталоги /home/$SHORT/<логин>"
  fi
  chown root:root $S; chmod 600 $S
  rm -f /var/lib/sss/db/* /var/lib/sss/mc/* /var/lib/sss/pubconf/kdcinfo.* 2>/dev/null

  step "5. Вход доменных пользователей (NSS и PAM)"
  if ! grep -qE '^passwd:.*sss' /etc/nsswitch.conf; then
    sed -i -E '/^(passwd|group|shadow):/{/sss/!s/$/ sss/}' /etc/nsswitch.conf; ok "В nsswitch.conf добавлен sss"
  else ok "nsswitch.conf уже использует sss"; fi
  if ! grep -qs pam_mkhomedir /etc/pam.d/common-session && ! grep -rqs pam_mkhomedir /usr/share/pam-configs/ 2>/dev/null; then
    printf 'Name: Create home directory on login (astra-helper)\nDefault: yes\nPriority: 0\nSession-Type: Additional\nSession-Interactive-Only: yes\nSession:\n\toptional\tpam_mkhomedir.so umask=0077\n' > /usr/share/pam-configs/astra-helper-mkhomedir
  fi
  if ! grep -qs pam_sss /etc/pam.d/common-auth || ! grep -qs pam_mkhomedir /etc/pam.d/common-session; then
    DEBIAN_FRONTEND=noninteractive pam-auth-update --enable sss mkhomedir astra-helper-mkhomedir >/dev/null 2>&1
    grep -qs pam_sss /etc/pam.d/common-auth || DEBIAN_FRONTEND=noninteractive pam-auth-update --package >/dev/null 2>&1
  fi
  PAMOK=1
  grep -qs pam_sss /etc/pam.d/common-auth && ok "PAM: pam_sss подключён" || { PAMOK=0; warn "PAM: pam_sss автоматически не подключился (файлы PAM изменены вручную)" "Выполните в терминале:  sudo pam-auth-update   и отметьте пробелом «SSS authentication»"; }
  grep -qs pam_mkhomedir /etc/pam.d/common-session && ok "PAM: домашние каталоги создаются при первом входе" || warn "PAM: создание домашних каталогов не подключилось" "sudo pam-auth-update  → отметьте «Create home directory on login»\nиначе создайте каталог вручную:  sudo mkdir -p /home/$SHORT/ЛОГИН && sudo chown ЛОГИН: /home/$SHORT/ЛОГИН"

  step "6. Запуск и проверка"
  systemctl enable sssd >/dev/null 2>&1; systemctl restart sssd 2>&1 | sed 's/^/       /'
  if ! systemctl is-active --quiet sssd; then
    journalctl -u sssd -b --no-pager 2>/dev/null | tail -8 | sed 's/^/       /'
    fail "Компьютер в домен введён, но служба sssd не запустилась" "Скопируйте строки выше — в них причина.\nПроверка конфигурации:  sudo sssctl config-check"
  fi
  ok "Служба sssd запущена"
  found=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    r=$(getent passwd "$DUSER" 2>/dev/null); [ -n "$r" ] && { found=1; break; }
    sleep 2
  done
  if [ -n "$found" ]; then u=$(id "$DUSER" 2>/dev/null | cut -c1-160); ok "Доменный пользователь виден: ${u:-$r}"
  else warn "Пользователь $DUSER пока не находится (id $DUSER) — SSSD мог ещё не связаться с контроллером" "Через минуту:  id $DUSER\nСостояние:  sudo sssctl domain-status $DOMAIN\nЖурнал:  sudo tail -30 /var/log/sssd/sssd_$DOMAIN.log"; fi
  have sssctl && sssctl domain-status "$DOMAIN" 2>/dev/null | grep -iE 'Online status|Active server|AD Domain Controller' | sed 's/^/       /'

  echo
  if [ "$PAMOK" = 1 ]; then echo "  [OK] Готово: компьютер $SAM в домене $DOMAIN. Перезагрузитесь и войдите под доменной учёткой."
  else echo "  [ВНИМАНИЕ] Компьютер в домене, но для входа пользователей нужно вручную подключить pam_sss (см. выше)."; fi
  echo "  Если при входе на Astra SE появится «нет доступных мандатных уровней»:  sudo pdpl-user -l 0:0 ЛОГИН"
  echo "[RESULT] join ok"
}

# ---------------------------------------------------------------- wizard (терминал)
do_wizard() {
  local def ans rows n i sel
  def=$(cfg /etc/sssd/sssd.conf domains | cut -d, -f1 | tr -d ' '); [ -z "$def" ] && def=$(hostname -d 2>/dev/null)
  [ -z "$DOMAIN" ] && { read -r -p "Домен [${def}]: " ans; DOMAIN=${ans:-$def}; }
  DOMAIN=$(echo "$DOMAIN" | tr 'A-Z' 'a-z'); REALM=$(echo "$DOMAIN" | tr 'a-z' 'A-Z')
  echo "Ищу контроллеры домена $DOMAIN и измеряю отклик…"
  rows=$(do_scan); site=$(echo "$rows" | awk '/^\[SITE\]/{print $2}')
  echo "$rows" | grep -q '^\[DC\]' || { echo "$rows"; return 1; }
  mapfile -t LIVE < <(echo "$rows" | sed -n 's/^\[DC\] //p' | awk -F'|' -v s="$site" '$3=="ok"{print ((s!="" && $6==s)?0:1) "|" $4+0 "|" $0}' | sort -t'|' -k1,1n -k2,2n | cut -d'|' -f3-)
  echo "$rows" | awk -F'|' '/^\[SCAN\]/{sub(/^\[SCAN\] /,""); print "Контроллеров в DNS: " $1 ", доступно: " $2 ", частично: " $3 ", не отвечают: " $4}'
  [ ${#LIVE[@]} -eq 0 ] && { echo "Нет ни одного доступного контроллера."; return 1; }
  [ -n "$site" ] && echo "Сайт AD этого компьютера: $site"
  printf '\n%3s  %-38s %-16s %7s  %s\n' "№" "Контроллер" "IP" "мс" "Сайт AD / примечание"
  i=0
  for l in "${LIVE[@]}"; do
    i=$((i+1)); IFS='|' read -r name ip st ms closed dsite csite short flags <<< "$l"
    note="$dsite"; [ -n "$site" ] && [ "$dsite" = "$site" ] && note="$note (ваш сайт)"
    case "$flags" in *dns*) note="$note, ваш DNS-сервер" ;; esac
    printf '%3s  %-38s %-16s %7s  %s\n' "$i" "$name" "$ip" "$ms" "$note"
    [ $i -ge 40 ] && { echo "     … показаны 40 ближайших"; break; }
  done
  read -r -p $'\nНомер основного контроллера [1]: ' n; n=${n:-1}
  read -r -p "Номера запасных через пробел (Enter — без запасных): " sel
  DCLIST=$(echo "${LIVE[$((n-1))]}" | cut -d'|' -f1)
  for i in $sel; do DCLIST="$DCLIST,$(echo "${LIVE[$((i-1))]}" | cut -d'|' -f1)"; done
  read -r -p "Добавить автопоиск остальных контроллеров как последний запасной (_srv_)? [Y/n] " ans
  case "$ans" in n|N|н|Н) USE_SRV=0 ;; *) USE_SRV=1 ;; esac
  read -r -p "Администратор домена (логин): " DUSER
  read -r -s -p "Пароль $DUSER: " PASS1; echo
  read -r -p "OU для учётки компьютера (Enter — по умолчанию): " OU
  PASSFILE=$(mktemp /tmp/astra-pw.XXXXXX); chmod 600 "$PASSFILE"; printf '%s\n' "$PASS1" > "$PASSFILE"
  do_precheck
  if [ $E -gt 0 ]; then read -r -p "Есть ошибки. Всё равно пробовать ввод в домен? [y/N] " ans; case "$ans" in y|Y|д|Д) ;; *) return 1 ;; esac
  else read -r -p "Ввести компьютер в домен $DOMAIN через ${DCLIST%%,*}? [y/N] " ans; case "$ans" in y|Y|д|Д) ;; *) return 0 ;; esac; fi
  E=0; W=0
  PASSFILE=$(mktemp /tmp/astra-pw.XXXXXX); chmod 600 "$PASSFILE"; printf '%s\n' "$PASS1" > "$PASSFILE"
  do_join
}

case "$MODE" in
  scan)     do_scan ;;
  precheck) do_precheck ;;
  join)     do_join ;;
  wizard)   do_wizard ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
