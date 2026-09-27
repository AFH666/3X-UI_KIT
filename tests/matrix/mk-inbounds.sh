#!/usr/bin/env bash
# Создаёт по подключению на каждый протокол через API 3x-ui. Запускать на сервере.
set -uo pipefail
. /etc/x-ui/install-result.env
API="http://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
H=(-H "Authorization: Bearer $XUI_API_TOKEN" -H 'Content-Type: application/json')
mkdir -p /root/cert
[[ -f /root/cert/crt ]] || openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /root/cert/key -out /root/cert/crt -subj /CN=test.pm -addext subjectAltName=DNS:test.pm -days 365 2>/dev/null
chmod 644 /root/cert/*
uuid() { cat /proc/sys/kernel/random/uuid; }
b64k() { openssl rand -base64 "$1"; }
cb() { jq -nc --arg e "$1" '{email:$e, limitIp:0, totalGB:0, expiryTime:0, enable:true, tgId:0, subId:$e, comment:"", reset:0}'; }
TLS=$(jq -nc '{serverName:"test.pm", certificates:[{certificateFile:"/root/cert/crt", keyFile:"/root/cert/key"}]}')
KEYS=$(curl -fsS "${H[@]}" "$API/server/getNewX25519Cert" | jq -c .obj)

add() { # remark port protocol settings stream
  local body r
  body=$(jq -nc --arg rm "$1" --argjson port "$2" --arg p "$3" --arg s "$4" --arg st "$5" \
    '{remark:$rm, enable:true, listen:"", port:$port, protocol:$p, settings:$s, streamSettings:$st,
      sniffing:"{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}", expiryTime:0, total:0}')
  r=$(curl -sS "${H[@]}" -X POST -d "$body" "$API/inbounds/add")
  printf '%-22s %s\n' "$1" "$(jq -r 'if .success then "создан" else "ОШИБКА: " + (.msg|tostring) end' <<<"$r" | head -c 300)"
}

add vless-xhttp-reality 8443 vless \
  "$(jq -nc --arg id "$(uuid)" --argjson c "$(cb t-xhttp)" '{clients:[$c + {id:$id, flow:""}], decryption:"none"}')" \
  "$(jq -nc --argjson k "$KEYS" --arg sid "$(openssl rand -hex 8)" '{network:"xhttp", security:"reality", xhttpSettings:{path:"/x", mode:"auto"},
     realitySettings:{target:"dl.google.com:443", serverNames:["dl.google.com"], privateKey:$k.privateKey, shortIds:[$sid], settings:{publicKey:$k.publicKey, fingerprint:"chrome", spiderX:"/"}}}')"

add vless-ws-tls 2053 vless \
  "$(jq -nc --arg id "$(uuid)" --argjson c "$(cb t-ws)" '{clients:[$c + {id:$id, flow:""}], decryption:"none"}')" \
  "$(jq -nc --argjson t "$TLS" '{network:"ws", security:"tls", wsSettings:{path:"/ws"}, tlsSettings:($t + {alpn:["http/1.1"]})}')"

add trojan-grpc-tls 2083 trojan \
  "$(jq -nc --argjson c "$(cb t-trojan)" --arg pw "$(openssl rand -hex 8)" '{clients:[$c + {password:$pw}]}')" \
  "$(jq -nc --argjson t "$TLS" '{network:"grpc", security:"tls", grpcSettings:{serviceName:"gun"}, tlsSettings:($t + {alpn:["h2"]})}')"

add vmess-ws-tls 2087 vmess \
  "$(jq -nc --arg id "$(uuid)" --argjson c "$(cb t-vmess)" '{clients:[$c + {id:$id, security:"auto", alterId:0}]}')" \
  "$(jq -nc --argjson t "$TLS" '{network:"ws", security:"tls", wsSettings:{path:"/vm"}, tlsSettings:($t + {alpn:["http/1.1"]})}')"

add shadowsocks-2022 8388 shadowsocks \
  "$(jq -nc --arg pw "$(b64k 16)" --arg upw "$(b64k 16)" --argjson c "$(cb t-ss)" '{method:"2022-blake3-aes-128-gcm", password:$pw, network:"tcp,udp", clients:[$c + {method:"", password:$upw}]}')" \
  '{"network":"tcp","security":"none"}'

add hysteria2 443 hysteria \
  "$(jq -nc --argjson c "$(cb t-hy2)" --arg a "$(openssl rand -hex 8)" '{version:2, clients:[$c + {auth:$a}]}')" \
  "$(jq -nc --argjson t "$TLS" '{network:"hysteria", hysteriaSettings:{version:2}, security:"tls", tlsSettings:($t + {alpn:["h3"]})}')"

add tuic 8444 tuic \
  "$(jq -nc --arg id "$(uuid)" --arg pw "$(openssl rand -hex 8)" --argjson c "$(cb t-tuic)" '{server:{certificate:"/root/cert/crt", private_key:"/root/cert/key", congestion_control:"bbr", alpn:["h3"], udp_relay_mode:"native", zero_rtt_handshake:false, log_level:"info", sni:""}, clients:[$c + {uuid:$id, id:$id, password:$pw}]}')" \
  '{}'

wgkey() { /usr/local/x-ui/bin/xray-linux-* wg | awk -v w="$1" 'tolower($0) ~ w {print $NF}'; }
WGK=$(/usr/local/x-ui/bin/xray-linux-* wg); WPRIV=$(awk '/Private/ {print $NF}' <<<"$WGK"); WPUB=$(awk '/Public|Password/ {print $NF}' <<<"$WGK" | head -1)
AGK=$(/usr/local/x-ui/bin/xray-linux-* wg); APRIV=$(awk '/Private/ {print $NF}' <<<"$AGK"); APUB=$(awk '/Public|Password/ {print $NF}' <<<"$AGK" | head -1)
add wireguard 51820 wireguard \
  "$(jq -nc --arg k "$(/usr/local/x-ui/bin/xray-linux-* wg | awk '/Private/ {print $NF}')" --arg pr "$WPRIV" --arg pu "$WPUB" --argjson c "$(cb t-wg)" '{mtu:1420, secretKey:$k, peers:[], clients:[$c + {privateKey:$pr, publicKey:$pu, allowedIPs:["10.0.0.2/32"]}], subnetIp:"10.0.0.0", subnetCidr:24}')" \
  '{"network":"tcp","security":"none"}'

add amneziawg 51821 amneziawg \
  "$(jq -nc --arg pr "$APRIV" --arg pu "$APUB" --argjson c "$(cb t-awg)" '{server:{subnetIp:"10.8.1.0", subnetCidr:24, primaryDns:"8.8.8.8", secondaryDns:"8.8.4.4"}, clients:[$c + {privateKey:$pr, publicKey:$pu, allowedIPs:["10.8.1.2/32"]}]}')" \
  '{}'

add mtproto 8445 mtproto \
  "$(jq -nc --argjson c "$(cb t-mtproto)" '{fakeTlsDomain:"www.cloudflare.com", clients:[$c + {secret:""}]}')" \
  '{}'
