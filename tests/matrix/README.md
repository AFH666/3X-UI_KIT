# Матрица «протокол × клиент»

Проверяет настоящим подключением, что каждый протокол 3X-UI работает с каждым клиентом:
Xray, Mihomo, sing-box и официальным клиентом AmneziaWG. Прогонять на каждой новой версии 3X-UI и Xray.

1. Сервер: чистый Ubuntu в Docker с systemd, на нём `scripts/3x-ui.sh`, затем `mk-inbounds.sh` —
   создаёт через API подключения VLESS XHTTP, WS+TLS, Trojan gRPC, VMess, Shadowsocks 2022,
   Hysteria2, TUIC, WireGuard, AmneziaWG и MTProto.
2. Ссылки: `GET /panel/api/inbounds/allLinks` → `links.txt`.
3. Конфиги клиентов: `PIN=<sha256 сертификата> node matrix-gen.js ../../tools/lib links.txt cases`.
4. Прогон в клиентском контейнере с бинарниками в `/cl`: `bash matrix-run.sh`.
5. AmneziaWG: `awg-set.sh classic|mid|full` меняет обфускацию на сервере.

Результат на 2026-09-27 (3X-UI 3.8.5, Xray 26.6.27, Mihomo 1.19.31, sing-box 1.14.2) — в описании коммита.
