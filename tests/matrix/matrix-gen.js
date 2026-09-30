// Генерирует конфиги клиентов для каждой пары «протокол × клиент».
const fs = require('fs'), path = require('path');
const [lib, linksFile, out] = process.argv.slice(2);
const PIN = process.env.PIN || ''; // отпечаток тестового сертификата сервера
const L = require(lib + '/links.js'), X = require(lib + '/xray.js'), M = require(lib + '/mihomo.js'), SB = require(lib + '/singbox.js');
const { proxies } = L.parseText(fs.readFileSync(linksFile, 'utf8'));
fs.rmSync(out, { recursive: true, force: true });
const rows = [];
proxies.filter((p) => p.type !== 'mtproto').forEach((p, i) => {
  // Тестовый сервер с самоподписанным сертификатом – разрешаем клиентам его принять.
  if (PIN && p.tls && p.tls.security === "tls") { p.tls.insecure = true; p.tls.pin = PIN; }
  if (PIN && (p.type === "hysteria2" || p.type === "tuic")) p.insecure = true;
  if (PIN && p.type === "hysteria2") p.pinSHA256 = PIN;
  const id = String(i).padStart(2, '0') + '-' + p.name.replace(/[^a-z0-9-]/gi, '').slice(0, 24);
  const dir = path.join(out, id);
  fs.mkdirSync(dir, { recursive: true });
  const res = { id, type: p.type, name: p.name };
  try {
    const x = X.buildXray([p], { finalProxy: true });
    const o = x.files['04_outbounds.json'];
    o.inbounds = [{ listen: '127.0.0.1', port: 1080, protocol: 'socks', settings: { udp: true } }];
    o.log = { loglevel: 'warning' };
    fs.writeFileSync(path.join(dir, 'xray.json'), JSON.stringify(o));
  } catch (e) { res.xray = 'n/a: ' + e.message; }
  try {
    fs.writeFileSync(path.join(dir, 'mihomo.yaml'), M.buildMihomo([p], { finalProxy: true, secret: 't', services: [] }).yaml + 'mixed-port: 1081\n');
  } catch (e) { res.mihomo = 'n/a: ' + e.message; }
  try {
    fs.writeFileSync(path.join(dir, 'singbox.json'), JSON.stringify(SB.buildSingbox([p], { inbound: { port: 1082 } }).config));
  } catch (e) { res.singbox = 'n/a: ' + e.message; }
  rows.push(res);
});
fs.writeFileSync(path.join(out, 'index.json'), JSON.stringify(rows, null, 1));
console.log(rows.map((r) => r.id + (r.xray ? ' [xray ' + r.xray + ']' : '') + (r.singbox ? ' [sb ' + r.singbox + ']' : '')).join('\n'));
