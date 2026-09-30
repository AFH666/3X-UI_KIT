#!/usr/bin/env bash
# awg-set.sh classic|full – выставляет обфускацию AmneziaWG на подключении и печатает ссылку.
. /etc/x-ui/install-result.env
API="http://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"; H=(-H "Authorization: Bearer $XUI_API_TOKEN" -H 'Content-Type: application/json')
ID=$(curl -fsS "${H[@]}" "$API/inbounds/list" | jq -r '.obj[] | select(.protocol=="amneziawg") | .id')
IN=$(curl -fsS "${H[@]}" "$API/inbounds/get/$ID" | jq -c .obj)
r() { shuf -i "$1-$2" -n 1; }
JMIN=$(r 40 89); S1=$(r 15 150); S2=$(r 15 150); while [[ $((S1+56)) == "$S2" ]]; do S2=$(r 15 150); done
OBF=$(jq -nc --argjson jc "$(r 3 6)" --argjson jmin $JMIN --argjson jmax $((JMIN + $(r 50 250))) --argjson s1 $S1 --argjson s2 $S2 \
  --arg h1 "$(r 5 536870911)" --arg h2 "$(r 536870912 1073741823)" --arg h3 "$(r 1073741824 1610612735)" --arg h4 "$(r 1610612736 2147483647)" \
  '{jc:$jc, jmin:$jmin, jmax:$jmax, s1:$s1, s2:$s2, h1:$h1, h2:$h2, h3:$h3, h4:$h4}')
if [[ $1 == mid ]]; then
  OBF=$(jq -c --argjson s3 "$(r 12 55)" --argjson s4 "$(r 12 27)" --arg i1 "<r $(r 32 256)>" ". + {s3:\$s3, s4:\$s4, i1:\$i1}" <<<"$OBF")
fi
if [[ $1 == full ]]; then
  OBF=$(jq -c --argjson s3 "$(r 12 55)" --argjson s4 "$(r 12 27)" --arg i1 "<r $(r 32 256)>" --arg hp "$(openssl rand -base64 32)" \
    '. + {s3:$s3, s4:$s4, i1:$i1, headerProtectionKey:$hp, contentPaddingAddition:"12-40", rekeyAfterTime:"110-140", rejectAfterTime:"180-250", rekeyTimeout:"4-7", keepaliveTimeout:"10-16", maxHandshakeAttempts:"20-40"}' <<<"$OBF")
fi
SET=$(jq -c --argjson o "$OBF" '(.settings | if type=="string" then fromjson else . end) | .server |= (del(.s3, .s4, .i1, .i2, .i3, .i4, .i5, .headerProtectionKey, .contentPaddingAddition, .rekeyAfterTime, .rejectAfterTime, .rekeyTimeout, .keepaliveTimeout, .maxHandshakeAttempts) + $o)' <<<"$IN")
BODY=$(jq -c --arg s "$SET" '.settings = $s | .streamSettings = (.streamSettings | if type=="string" then . else tojson end) | .sniffing = (.sniffing | if type=="string" then . else tojson end)' <<<"$IN")
curl -fsS "${H[@]}" -X POST -d "$BODY" "$API/inbounds/update/$ID" | jq -r '.success, (.msg|tostring)' | tr '\n' ' '; echo
sleep 2
curl -fsS "${H[@]}" -H "Host: xs" "$API/inbounds/allLinks" | jq -r '.obj[] | select(startswith("vpn://"))'
