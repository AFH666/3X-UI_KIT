#!/usr/bin/env bash
# 3X-UI со всеми протоколами одной командой — https://github.com/itsnotkubrick/Reality_Hysteria2
#
# Установка:  bash <(curl -fsSL https://raw.githubusercontent.com/itsnotkubrick/Reality_Hysteria2/main/scripts/3x-ui.sh)
#
# Ставит официальную панель 3X-UI (версия закреплена ниже) её собственным
# установщиком, получает сертификат Let's Encrypt на IP, создаёт подключения
# REALITY, XHTTP, VLESS/VMess WS, Trojan gRPC, Shadowsocks 2022, Hysteria2, TUIC,
# WireGuard, AmneziaWG (классика и 3.1) и MTProto, включает единую подписку
# с форматом под каждый клиент и настраивает ufw. Домены не нужны.
# Каждый протокол проверен настоящими клиентами — см. tests/matrix.

set -Eeuo pipefail

XUI_VERSION="v3.8.5"
# Ядро Xray для панели. С 26.7.x клиенты на Mihomo и sing-box (Hiddify, FlClash,
# Clash Verge, Mihomo в XKeen) не проходят REALITY — проверено 2026-09-25.
# 26.6.27 — последняя версия, с которой работают все клиенты и которую принимает 3X-UI.
XRAY_CORE="v26.6.27"
XUI_REPO="MHSanaei/3x-ui"
RESULT=/root/3x-ui.txt
XUI_ENV=/etc/x-ui/install-result.env
# Сайты для маскировки REALITY: нужны TLS 1.3 и HTTP/2. Берём первый доступный.
# Apple, iCloud, Microsoft и домены .ru сам Xray не советует — их тут нет.
SNI_CANDIDATES=(dl.google.com www.amazon.com www.samsung.com www.yahoo.com)

ALL_PROTOS=(reality hy2 xhttp ws trojan vmess ss tuic wg awg awg3 mtproto)
declare -A PORTS=([xhttp]=8443 [ws]=2053 [trojan]=2083 [vmess]=2087 [ss]=8388 [tuic]=8444 [wg]=51820 [awg]=51821 [awg3]=51822 [mtproto]=8445)
PROTOS=(); CREATED=(); OPEN=()

if [[ -t 1 ]]; then
  G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
  G=; Y=; R=; B=; D=; N=
fi
say()  { printf '%s\n' "${G}==>${N} $*"; }
warn() { printf '%s\n' "${Y}!${N}  $*" >&2; }
die()  { printf '%s\n' "${R}✗${N}  $*" >&2; exit 1; }
trap 'die "Ошибка в строке $LINENO. Исправьте причину и запустите скрипт ещё раз."' ERR

rand_str() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "$1"; }
port_busy() { ss -H -ln"${2:0:1}" "sport = :$1" 2>/dev/null | grep -q .; }

public_ip() {
  local ip
  for u in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
    ip=$(curl -4 -fsS -m 6 "$u" 2>/dev/null | tr -d '[:space:]') || true
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return; }
  done
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'
}

free_port() {
  local p
  for _ in $(seq 1 50); do
    p=$(shuf -i 20000-60000 -n 1)
    port_busy "$p" tcp || { echo "$p"; return; }
  done
  die "Не нашёл свободный порт для панели."
}

# REALITY маскируется под чужой сайт: он должен отвечать по TLS 1.3 и HTTP/2.
sni_ok() {
  echo | timeout 8 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 -alpn h2 2>/dev/null \
    | grep -q 'ALPN protocol: h2'
}

# ---------- API панели ----------

api() { # METHOD path [json]
  local url="$API/$2" out
  if [[ $1 == GET ]]; then
    out=$(curl -fsSk -m 20 -H "Authorization: Bearer $TOKEN" "$url")
  else
    out=$(curl -fsSk -m 20 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X "$1" -d "$3" "$url")
  fi
  [[ $(jq -r '.success' <<<"$out") == true ]] || die "Панель ответила ошибкой на $2: $(jq -r '.msg // .' <<<"$out" | head -c 300)"
  jq -c '.obj' <<<"$out"
}

wait_panel() {
  local i
  for i in $(seq 1 60); do
    curl -fsk -m 5 -o /dev/null -H "Authorization: Bearer $TOKEN" "$API/server/getNewUUID" 2>/dev/null && return 0
    sleep 2
  done
  die "Панель не отвечает. Лог: journalctl -u x-ui -n 50"
}

# ---------- установка ----------

main() {
  [[ $EUID -eq 0 ]] || die "Запустите от root: sudo -i, затем команду ещё раз."
  command -v systemctl >/dev/null || die "Нужен systemd."
  [[ -f $RESULT ]] && die "3X-UI уже установлена этим скриптом. Управление: команда x-ui, данные для входа: cat $RESULT"
  if [[ -d /usr/local/x-ui && ! -f $XUI_ENV ]]; then
    die "3X-UI уже установлена другим способом — не трогаю её. Удалите её (x-ui uninstall) или добавьте REALITY в панели вручную."
  fi

  local PORT=443 SNI="" PANEL_SSL=auto HOST="" UFW=yes NAME="admin" yes=no protos=all ucert="" ukey=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --port) PORT=$2; shift 2 ;;
      --sni) SNI=$2; shift 2 ;;
      --panel-ssl) PANEL_SSL=$2; shift 2 ;;
      --host) HOST=$2; shift 2 ;;
      --user) NAME=$2; shift 2 ;;
      --protocols) protos=$2; shift 2 ;;
      --cert) ucert=$2; shift 2 ;;
      --key) ukey=$2; shift 2 ;;
      --no-ufw) UFW=no; shift ;;
      -y|--yes) yes=yes; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Неизвестный параметр: $1 (см. --help)" ;;
    esac
  done
  [[ $PORT =~ ^[0-9]+$ ]] && ((PORT > 0 && PORT < 65536)) || die "Неверный порт: $PORT"
  [[ $NAME =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "Имя: латиница, цифры, _ . - (до 32 символов)."
  [[ $PANEL_SSL =~ ^(auto|ip|none)$ ]] || die "--panel-ssl: auto, ip или none"
  if [[ -n $ucert || -n $ukey ]]; then
    [[ -s $ucert && -s $ukey ]] || die "Нужны оба файла: --cert fullchain.pem --key privkey.pem"
    openssl x509 -in "$ucert" -noout 2>/dev/null || die "$ucert — не сертификат в формате PEM"
    PANEL_SSL=custom
  fi
  case $protos in
    all) PROTOS=("${ALL_PROTOS[@]}") ;;
    minimal) PROTOS=(reality) ;;
    *) IFS=, read -ra PROTOS <<<"$protos"
       local x
       for x in "${PROTOS[@]}"; do [[ " ${ALL_PROTOS[*]} " == *" $x "* ]] || die "Неизвестный протокол: $x. Доступны: ${ALL_PROTOS[*]}"; done ;;
  esac
  if port_busy "$PORT" tcp && ! { [[ -f $XUI_ENV ]] && ss -H -ltnp "sport = :$PORT" | grep -q xray; }; then
    die "Порт $PORT/tcp уже занят. REALITY нужен свободный порт — укажите другой: --port 8443"
  fi

  if [[ $PANEL_SSL == auto ]]; then
    if port_busy 80 tcp; then
      PANEL_SSL=none
      warn "Порт 80 занят — сертификат для панели не получить. Панель будет доступна только через SSH-туннель."
    else
      PANEL_SSL=ip
    fi
  fi
  [[ $PANEL_SSL == ip ]] && port_busy 80 tcp && die "Для сертификата панели нужен свободный порт 80/tcp."
  # Доверенный сертификат (Let's Encrypt или свой) — панель и подписка доступны снаружи по HTTPS.
  TRUSTED=no
  [[ $PANEL_SSL == ip || $PANEL_SSL == custom ]] && TRUSTED=yes
  if [[ $PANEL_SSL == custom ]]; then
    mkdir -p /root/cert/custom
    install -m 644 "$ucert" /root/cert/custom/fullchain.pem
    install -m 600 "$ukey" /root/cert/custom/privkey.pem
  fi

  say "Ставлю пакеты: curl, jq, openssl, qrencode, ufw"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl jq openssl qrencode ca-certificates iproute2 ufw socat cron >/dev/null

  HOST=${HOST:-$(public_ip)}
  [[ -n $HOST ]] || die "Не удалось узнать внешний IP. Укажите его: --host 1.2.3.4"

  if [[ -z $SNI ]]; then
    say "Выбираю сайт для маскировки REALITY"
    for s in "${SNI_CANDIDATES[@]}"; do
      if sni_ok "$s"; then SNI=$s; break; fi
    done
    [[ -n $SNI ]] || die "Ни один сайт из списка не ответил по TLS 1.3 + HTTP/2. Укажите свой: --sni example.com"
  elif ! sni_ok "$SNI"; then
    die "$SNI не отвечает по TLS 1.3 + HTTP/2 — REALITY с ним работать не будет. Выберите другой сайт."
  fi
  say "Маскировка: ${B}$SNI${N}"

  # --- официальный установщик 3X-UI с закреплённой версией ---
  local panel_port panel_path panel_user panel_pass tmp
  panel_port=$(free_port)
  panel_path=$(rand_str 18)
  panel_user=$(rand_str 10)
  panel_pass=$(rand_str 20)
  if [[ -f $XUI_ENV ]]; then
    say "3X-UI уже стоит после прошлого запуска — продолжаю с создания подключений"
  else
  tmp=$(mktemp)
  say "Ставлю 3X-UI $XUI_VERSION официальным установщиком (пара минут)"
  curl -fsSL --retry 3 -o "$tmp" "https://raw.githubusercontent.com/$XUI_REPO/$XUI_VERSION/install.sh"
  if ! XUI_NONINTERACTIVE=1 XUI_SSL_MODE="${PANEL_SSL/custom/none}" XUI_SERVER_IP="$HOST" \
      XUI_PANEL_PORT="$panel_port" XUI_WEB_BASE_PATH="$panel_path" \
      XUI_USERNAME="$panel_user" XUI_PASSWORD="$panel_pass" \
      bash "$tmp" "$XUI_VERSION" </dev/null >/var/log/3x-ui-install.log 2>&1; then
    tail -20 /var/log/3x-ui-install.log >&2
    die "Установщик 3X-UI завершился с ошибкой. Полный лог: /var/log/3x-ui-install.log"
  fi
  rm -f "$tmp"
  fi
  [[ -f $XUI_ENV ]] || die "Установщик не сохранил данные входа. Лог: /var/log/3x-ui-install.log"

  # Данные для входа — из файла, который пишет сам установщик.
  # shellcheck disable=SC1090
  . "$XUI_ENV"
  TOKEN=$XUI_API_TOKEN
  local scheme=http
  [[ $XUI_ACCESS_URL == https://* ]] && scheme=https
  API="$scheme://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
  wait_panel

  if [[ $PANEL_SSL == custom ]]; then
    say "Подключаю ваш сертификат к панели"
    /usr/local/x-ui/x-ui cert -webCert /root/cert/custom/fullchain.pem -webCertKey /root/cert/custom/privkey.pem >/dev/null 2>&1
    systemctl restart x-ui
    API="https://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
    wait_panel
  fi

  # Без сертификата панель и подписки не должны торчать наружу по HTTP.
  if [[ $PANEL_SSL == none ]]; then
    say "Панель без сертификата — открываю её только для SSH-туннеля (127.0.0.1)"
    local all
    all=$(api POST setting/all '{}')
    api POST setting/update "$(jq -c '.webListen = "127.0.0.1" | .subListen = "127.0.0.1"' <<<"$all")" >/dev/null
    systemctl restart x-ui
    wait_panel
  fi

  # --- ядро Xray, совместимое со всеми клиентами ---
  local cur_core
  cur_core=$(/usr/local/x-ui/bin/xray-linux-* version 2>/dev/null | awk 'NR==1 {print "v" $2}')
  if [[ $cur_core != "$XRAY_CORE" ]]; then
    say "Ставлю ядро Xray $XRAY_CORE (совместимо с Hiddify, Mihomo и другими клиентами)"
    api POST "server/installXray/$XRAY_CORE" '{}' >/dev/null
    for _ in $(seq 1 30); do
      cur_core=$(/usr/local/x-ui/bin/xray-linux-* version 2>/dev/null | awk 'NR==1 {print "v" $2}')
      [[ $cur_core == "$XRAY_CORE" ]] && break
      sleep 2
    done
    [[ $cur_core == "$XRAY_CORE" ]] || warn "Не удалось сменить ядро Xray (сейчас $cur_core). Клиенты на Mihomo и sing-box могут не подключиться."
  fi

  # --- сертификат для протоколов с TLS ---
  setup_tls_cert

  # --- подключения: все выбранные протоколы, один subId на пользователя ---
  SUBID=$(tr 'A-Z' 'a-z' <<<"$NAME")
  EXISTING=$(api GET inbounds/list)
  local p
  for p in "${PROTOS[@]}"; do "proto_$p"; done

  # --- подписка: ссылки, Clash/Mihomo и JSON с автоопределением клиента ---
  setup_subscription

  # --- файрвол ---
  if [[ $UFW == yes ]]; then
    local ssh_port
    ssh_port=$(ss -H -ltnp 2>/dev/null | awk '/sshd/ {sub(/.*:/,"",$4); print $4; exit}')
    ssh_port=${ssh_port:-22}
    OPEN+=("$ssh_port/tcp")
    [[ $TRUSTED == yes ]] && OPEN+=("$XUI_PANEL_PORT/tcp" "$SUB_PORT/tcp")
    [[ $PANEL_SSL == ip ]] && OPEN+=("80/tcp")
    say "Настраиваю ufw: ${OPEN[*]}"
    local o
    for o in "${OPEN[@]}"; do ufw allow "$o" >/dev/null; done
    ufw --force enable >/dev/null || warn "ufw не включился (так бывает в контейнерах) — откройте порты у хостера вручную."
  fi

  # --- итог ---
  local panel_url links
  if [[ $TRUSTED == yes ]]; then
    panel_url="https://$HOST:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH"
  else
    panel_url="http://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH  (через SSH-туннель: ssh -L $XUI_PANEL_PORT:127.0.0.1:$XUI_PANEL_PORT root@$HOST)"
  fi
  links=$(sub_links)
  umask 077
  {
    echo "3X-UI $XUI_VERSION — данные для входа (файл виден только root)"
    echo
    echo "Панель:  $panel_url"
    echo "Логин:   $XUI_USERNAME"
    echo "Пароль:  $XUI_PASSWORD"
    echo
    [[ $TRUSTED == yes ]] && { echo "Подписка ($NAME) — все протоколы одной ссылкой:"; echo "$SUB_URL"; echo; }
    echo "Отдельные подключения ($NAME):"
    echo "$links"
  } >"$RESULT"

  echo
  echo "${G}${B}Готово! 3X-UI работает: ${#CREATED[@]} протоколов.${N}"
  echo "${D}${CREATED[*]}${N}"
  echo
  echo "Панель:  ${B}$panel_url${N}"
  echo "Логин:   ${B}$XUI_USERNAME${N}"
  echo "Пароль:  ${B}$XUI_PASSWORD${N}"
  echo
  if [[ $TRUSTED == yes ]]; then
    echo "Подписка для ${B}$NAME${N} — все протоколы одной ссылкой. Вставьте её в Hiddify, v2rayN, Happ,"
    echo "Clash Verge или FlClash: приложение само получит подходящий формат."
    echo
    echo "$SUB_URL"
    echo
    qrencode -t ANSIUTF8 -m 1 "$SUB_URL" || true
  else
    echo "Без сертификата подписка недоступна снаружи — вот ссылки по одной:"
    echo
    echo "$links"
  fi
  echo
  if [[ -n $PIN && " ${CREATED[*]} " == *" TUIC "* ]]; then
    warn "TUIC со своим сертификатом: в клиенте включите «Разрешить небезопасный» (allow insecure) — отпечаток TUIC-ссылки не передают."
  fi
  echo "Всё это сохранено в ${B}$RESULT${N}. Друзей добавляйте в панели: Клиенты → Добавить клиента,"
  echo "отметьте все подключения и задайте одинаковый Subscription ID — у друга будет своя подписка."
}

# ---------- сертификат ----------

setup_tls_cert() {
  PIN=""
  if [[ $PANEL_SSL == custom ]]; then
    CERT=/root/cert/custom/fullchain.pem; KEY=/root/cert/custom/privkey.pem
  elif [[ $PANEL_SSL == ip && -s /root/cert/ip/fullchain.pem ]]; then
    CERT=/root/cert/ip/fullchain.pem; KEY=/root/cert/ip/privkey.pem
  else
    # Без Let's Encrypt — свой сертификат, а его отпечаток уходит в ссылки (pcs),
    # чтобы клиенты доверяли именно ему.
    CERT=/root/cert/self/fullchain.pem; KEY=/root/cert/self/privkey.pem
    if [[ ! -s $CERT ]]; then
      mkdir -p /root/cert/self
      local san="DNS:$HOST"
      [[ $HOST =~ ^[0-9.]+$ ]] && san="IP:$HOST"
      openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout "$KEY" -out "$CERT" \
        -subj "/CN=$HOST" -addext "subjectAltName=$san" -days 3650 2>/dev/null
      chmod 600 "$KEY"
    fi
    PIN=$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
  fi
}

tls_json() { # alpn(JSON-массив)
  jq -nc --arg sni "$HOST" --arg c "$CERT" --arg k "$KEY" --arg pin "$PIN" --argjson alpn "$1" '{
    serverName: $sni, alpn: $alpn, certificates: [{certificateFile: $c, keyFile: $k}],
    settings: ({fingerprint: "chrome"} + (if $pin != "" then {pinnedPeerCertSha256: [$pin]} else {} end))}'
}

# ---------- протоколы ----------

client_base() { # суффикс
  jq -nc --arg e "$NAME-$1" --arg s "$SUBID" '{email: $e, limitIp: 0, totalGB: 0, expiryTime: 0, enable: true, tgId: 0, subId: $s, comment: "", reset: 0}'
}
uuid() { cat /proc/sys/kernel/random/uuid; }
rnd() { shuf -i "$1-$2" -n 1; }

# add_inbound remark port proto(tcp|udp|both) protocol settings stream
add_inbound() {
  local remark=$1 port=$2 net=$3 protocol=$4 settings=$5 stream=$6 body
  if jq -e --arg r "$remark" 'any(.[]; .remark == $r)' <<<"$EXISTING" >/dev/null; then
    CREATED+=("$remark"); open_port "$port" "$net"; return
  fi
  local n
  for n in ${net/both/tcp udp}; do
    if port_busy "$port" "$n"; then warn "$remark пропущен: порт $port/$n занят"; return; fi
  done
  body=$(jq -nc --arg rm "$remark" --argjson port "$port" --arg p "$protocol" --arg s "$settings" --arg st "$stream" '{
    remark: $rm, enable: true, listen: "", port: $port, protocol: $p, settings: $s, streamSettings: $st,
    sniffing: "{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"metadataOnly\":false,\"routeOnly\":false}",
    expiryTime: 0, total: 0}')
  if api POST inbounds/add "$body" >/dev/null; then
    CREATED+=("$remark"); open_port "$port" "$net"
  fi
}

open_port() { # port net
  case $2 in
    tcp|udp) OPEN+=("$1/$2") ;;
    both) OPEN+=("$1/tcp" "$1/udp") ;;
  esac
}

proto_reality() {
  local keys stream settings
  keys=$(api GET server/getNewX25519Cert)
  settings=$(jq -nc --arg id "$(uuid)" --argjson c "$(client_base reality)" '{clients: [$c + {id: $id, flow: "xtls-rprx-vision"}], decryption: "none", fallbacks: []}')
  stream=$(jq -nc --arg sni "$SNI" --argjson k "$keys" --arg sid "$(openssl rand -hex 8)" '{
    network: "tcp", security: "reality", externalProxy: [],
    realitySettings: {show: false, xver: 0, target: ($sni + ":443"), serverNames: [$sni], privateKey: $k.privateKey,
      minClientVer: "", maxClientVer: "", maxTimediff: 0, shortIds: [$sid],
      settings: {publicKey: $k.publicKey, fingerprint: "chrome", serverName: "", spiderX: "/"}},
    tcpSettings: {acceptProxyProtocol: false, header: {type: "none"}}}')
  add_inbound "REALITY" "$PORT" tcp vless "$settings" "$stream"
}

proto_xhttp() {
  local keys stream settings
  keys=$(api GET server/getNewX25519Cert)
  settings=$(jq -nc --arg id "$(uuid)" --argjson c "$(client_base xhttp)" '{clients: [$c + {id: $id, flow: ""}], decryption: "none"}')
  stream=$(jq -nc --arg sni "$SNI" --argjson k "$keys" --arg sid "$(openssl rand -hex 8)" --arg path "/$(rand_str 10 | tr 'A-Z' 'a-z')" '{
    network: "xhttp", security: "reality", xhttpSettings: {path: $path, mode: "auto"},
    realitySettings: {target: ($sni + ":443"), serverNames: [$sni], privateKey: $k.privateKey, shortIds: [$sid],
      settings: {publicKey: $k.publicKey, fingerprint: "chrome", spiderX: "/"}}}')
  add_inbound "XHTTP" "${PORTS[xhttp]}" tcp vless "$settings" "$stream"
}

proto_ws() {
  local settings stream
  settings=$(jq -nc --arg id "$(uuid)" --argjson c "$(client_base ws)" '{clients: [$c + {id: $id, flow: ""}], decryption: "none"}')
  stream=$(jq -nc --argjson t "$(tls_json '["http/1.1"]')" --arg path "/$(rand_str 10 | tr 'A-Z' 'a-z')" '{network: "ws", security: "tls", wsSettings: {path: $path}, tlsSettings: $t}')
  add_inbound "VLESS-WS" "${PORTS[ws]}" tcp vless "$settings" "$stream"
}

proto_trojan() {
  local settings stream
  settings=$(jq -nc --arg pw "$(rand_str 16)" --argjson c "$(client_base trojan)" '{clients: [$c + {password: $pw}]}')
  stream=$(jq -nc --argjson t "$(tls_json '["h2"]')" --arg sn "$(rand_str 8 | tr 'A-Z' 'a-z')" '{network: "grpc", security: "tls", grpcSettings: {serviceName: $sn}, tlsSettings: $t}')
  add_inbound "Trojan-gRPC" "${PORTS[trojan]}" tcp trojan "$settings" "$stream"
}

proto_vmess() {
  local settings stream
  settings=$(jq -nc --arg id "$(uuid)" --argjson c "$(client_base vmess)" '{clients: [$c + {id: $id, security: "auto", alterId: 0}]}')
  stream=$(jq -nc --argjson t "$(tls_json '["http/1.1"]')" --arg path "/$(rand_str 10 | tr 'A-Z' 'a-z')" '{network: "ws", security: "tls", wsSettings: {path: $path}, tlsSettings: $t}')
  add_inbound "VMess-WS" "${PORTS[vmess]}" tcp vmess "$settings" "$stream"
}

proto_ss() {
  local settings
  settings=$(jq -nc --arg pw "$(openssl rand -base64 16)" --arg upw "$(openssl rand -base64 16)" --argjson c "$(client_base ss)" '{
    method: "2022-blake3-aes-128-gcm", password: $pw, network: "tcp,udp", clients: [$c + {method: "", password: $upw}]}')
  add_inbound "Shadowsocks" "${PORTS[ss]}" both shadowsocks "$settings" '{"network":"tcp","security":"none"}'
}

proto_hy2() {
  local settings stream
  settings=$(jq -nc --arg a "$(rand_str 16)" --argjson c "$(client_base hy2)" '{version: 2, clients: [$c + {auth: $a}]}')
  stream=$(jq -nc --argjson t "$(tls_json '["h3"]')" '{network: "hysteria", hysteriaSettings: {version: 2}, security: "tls", tlsSettings: $t}')
  add_inbound "Hysteria2" "$PORT" udp hysteria "$settings" "$stream"
}

proto_tuic() {
  local settings id
  id=$(uuid)
  settings=$(jq -nc --arg id "$id" --arg pw "$(rand_str 16)" --arg c "$CERT" --arg k "$KEY" --argjson cb "$(client_base tuic)" '{
    server: {certificate: $c, private_key: $k, congestion_control: "bbr", alpn: ["h3"], udp_relay_mode: "native",
      zero_rtt_handshake: false, log_level: "warn", sni: ""},
    clients: [$cb + {uuid: $id, id: $id, password: $pw}]}')
  add_inbound "TUIC" "${PORTS[tuic]}" udp tuic "$settings" '{}'
}

wg_pair() { /usr/local/x-ui/bin/xray-linux-* wg; }

proto_wg() {
  local srv cli settings
  srv=$(wg_pair); cli=$(wg_pair)
  settings=$(jq -nc --arg sk "$(awk '/Private/ {print $NF}' <<<"$srv")" \
    --arg pr "$(awk '/Private/ {print $NF}' <<<"$cli")" --arg pu "$(awk '/Public|Password/ {print $NF}' <<<"$cli" | head -1)" \
    --argjson c "$(client_base wg)" '{mtu: 1420, secretKey: $sk, peers: [], subnetIp: "10.0.0.0", subnetCidr: 24,
    clients: [$c + {privateKey: $pr, publicKey: $pu, allowedIPs: ["10.0.0.2/32"]}]}')
  add_inbound "WireGuard" "${PORTS[wg]}" udp wireguard "$settings" '{"network":"tcp","security":"none"}'
}

# AmneziaWG: классические параметры понимают Mihomo и роутеры Keenetic,
# полный набор 3.1 — только приложения AmneziaVPN/AmneziaWG. Поэтому два подключения.
awg_obfuscation() { # classic|full
  local jmin s1 s2
  jmin=$(rnd 40 89); s1=$(rnd 15 150); s2=$(rnd 15 150)
  while ((s1 + 56 == s2)); do s2=$(rnd 15 150); done
  local o
  o=$(jq -nc --argjson jc "$(rnd 3 6)" --argjson jmin "$jmin" --argjson jmax "$((jmin + $(rnd 50 250)))" --argjson s1 "$s1" --argjson s2 "$s2" \
    --arg h1 "$(rnd 5 536870911)" --arg h2 "$(rnd 536870912 1073741823)" --arg h3 "$(rnd 1073741824 1610612735)" --arg h4 "$(rnd 1610612736 2147483647)" \
    '{jc: $jc, jmin: $jmin, jmax: $jmax, s1: $s1, s2: $s2, h1: $h1, h2: $h2, h3: $h3, h4: $h4}')
  if [[ $1 == full ]]; then
    local cp rk rj rt ka ha
    cp=$(rnd 8 24); rk=$(rnd 100 120); rj=$((rk + $(rnd 10 40) + $(rnd 30 60))); rt=$(rnd 3 6); ka=$(rnd 8 12); ha=$(rnd 15 25)
    o=$(jq -c --argjson s3 "$(rnd 12 55)" --argjson s4 "$(rnd 12 27)" --arg i1 "<r $(rnd 32 256)>" --arg hp "$(openssl rand -base64 32)" \
      --arg cp "$cp-$((cp + $(rnd 8 40)))" --arg rk "$rk-$((rk + $(rnd 10 40)))" --arg rj "$rj-$((rj + $(rnd 30 90)))" \
      --arg rt "$rt-$((rt + $(rnd 1 4)))" --arg ka "$ka-$((ka + $(rnd 2 8)))" --arg ha "$ha-$((ha + $(rnd 5 25)))" \
      '. + {s3: $s3, s4: $s4, i1: $i1, headerProtectionKey: $hp, contentPaddingAddition: $cp, rekeyAfterTime: $rk,
            rejectAfterTime: $rj, rekeyTimeout: $rt, keepaliveTimeout: $ka, maxHandshakeAttempts: $ha}' <<<"$o")
  fi
  echo "$o"
}

awg_inbound() { # remark port subnet client-ip suffix mode
  local srv cli settings
  srv=$(wg_pair); cli=$(wg_pair)
  settings=$(jq -nc --arg pk "$(awk '/Private/ {print $NF}' <<<"$srv")" --arg pub "$(awk '/Public|Password/ {print $NF}' <<<"$srv" | head -1)" \
    --arg pr "$(awk '/Private/ {print $NF}' <<<"$cli")" --arg pu "$(awk '/Public|Password/ {print $NF}' <<<"$cli" | head -1)" \
    --arg net "$3" --arg ip "$4" --argjson o "$(awg_obfuscation "$6")" --argjson c "$(client_base "$5")" '{
    server: ({privateKey: $pk, publicKey: $pub, subnetIp: $net, subnetCidr: 24, primaryDns: "1.1.1.1", secondaryDns: "8.8.8.8"} + $o),
    clients: [$c + {privateKey: $pr, publicKey: $pu, allowedIPs: [$ip]}]}')
  add_inbound "$1" "$2" udp amneziawg "$settings" '{}'
}

proto_awg() { awg_inbound "AmneziaWG" "${PORTS[awg]}" 10.8.1.0 10.8.1.2/32 awg classic; }
proto_awg3() { awg_inbound "AmneziaWG-3.1" "${PORTS[awg3]}" 10.8.2.0 10.8.2.2/32 awg3 full; }

proto_mtproto() {
  local settings
  settings=$(jq -nc --argjson c "$(client_base mtproto)" '{fakeTlsDomain: "www.cloudflare.com", clients: [$c + {secret: ""}]}')
  add_inbound "MTProto" "${PORTS[mtproto]}" tcp mtproto "$settings" '{}'
}

# ---------- подписка ----------

setup_subscription() {
  local all
  all=$(api POST setting/all '{}')
  SUB_PORT=$(jq -r '.subPort // 2096' <<<"$all")
  SUB_PATH=$(jq -r '.subPath // "/sub/"' <<<"$all")
  if [[ $SUB_PATH == /sub/ || -z $SUB_PATH ]]; then SUB_PATH="/$(rand_str 12 | tr 'A-Z' 'a-z')/"; fi
  local upd
  upd=$(jq -c --arg path "$SUB_PATH" --arg c "$CERT" --arg k "$KEY" --arg ssl "$TRUSTED" --arg title "3X-UI + Hysteria2 Kit" '
    .subEnable = true | .subPath = $path | .subTitle = $title
    | .subClashEnable = true | .subClashAutoDetect = true | .subJsonEnable = true | .subJsonAutoDetect = true
    | if $ssl == "yes" then .subCertFile = $c | .subKeyFile = $k | .subListen = "" else . end' <<<"$all")
  if [[ $upd != "$all" ]]; then
    api POST setting/update "$upd" >/dev/null
    systemctl restart x-ui
    wait_panel
  fi
  if [[ $TRUSTED == yes ]]; then SUB_URL="https://$HOST:$SUB_PORT$SUB_PATH$SUBID"; else SUB_URL="http://127.0.0.1:$SUB_PORT$SUB_PATH$SUBID"; fi
  SUB_FETCH="$(if [[ $TRUSTED == yes ]]; then echo https; else echo http; fi)://$HOST:$SUB_PORT$SUB_PATH$SUBID"
}

# Ссылки пользователя — из его же подписки (её собирает сама 3X-UI).
sub_links() {
  local raw i
  for i in $(seq 1 20); do
    # Запрос идёт на этот же сервер, но с настоящим адресом в Host — 3X-UI подставит его в ссылки.
    raw=$(curl -fsSk -m 10 -A "v2rayN/7.0" --connect-to "$HOST:$SUB_PORT:127.0.0.1:$SUB_PORT" \
      "$SUB_FETCH" 2>/dev/null) && [[ -n $raw ]] && break
    sleep 2
  done
  if grep -q '://' <<<"$raw"; then echo "$raw"; else base64 -d <<<"$raw" 2>/dev/null; fi
}

usage() {
  cat <<EOF
3X-UI со всеми протоколами одной командой

  --protocols all     all (по умолчанию), minimal (только REALITY) или список через запятую:
                      reality,hy2,xhttp,ws,trojan,vmess,ss,tuic,wg,awg,awg3,mtproto
  --port 443          порт REALITY (TCP) и Hysteria2 (UDP), по умолчанию 443
  --sni сайт          сайт для маскировки (по умолчанию подбирается сам)
  --panel-ssl ip|none сертификат панели: ip — Let's Encrypt на IP (нужен порт 80),
                      none — панель только через SSH-туннель (по умолчанию выбирается сам)
  --cert файл --key файл  свой сертификат (например, для домена) вместо Let's Encrypt на IP;
                      тогда --host — это домен из сертификата
  --user admin        имя первого клиента
  --host 1.2.3.4      адрес в ссылке, если IP определился неверно
  --no-ufw            не трогать файрвол
  -y                  не задавать вопросов
EOF
}

main "$@"
