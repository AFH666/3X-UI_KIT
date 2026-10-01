// Роутеры и команды для SSH: куда положить готовые файлы и как перезапустить прокси.
(function (root) {
  'use strict';

  // Что умеет каждый роутер: на Keenetic работает XKeen (Xray или Mihomo), на OpenWrt – Nikki (только Mihomo).
  const ROUTERS = {
    keenetic: { label: 'Keenetic', hint: 'через XKeen', cores: ['xray', 'mihomo'], ssh: 'ssh root@192.168.x.x -p 222' },
    openwrt: { label: 'OpenWrt', hint: 'через Nikki, только Mihomo (бета)', cores: ['mihomo'], ssh: 'ssh root@192.168.x.x' },
  };
  const CORES = {
    xray: { label: 'Xray', hint: '04_outbounds.json и 05_routing.json' },
    mihomo: { label: 'Mihomo', hint: 'config.yaml: автовыбор сервера, Hysteria2, TUIC, AmneziaWG, веб-панель' },
  };
  const NIKKI_PROFILE = '3x-ui-kit.yaml';
  const NIKKI_DIR = '/etc/nikki/profiles';

  // Файл целиком через heredoc: если метка встретилась внутри файла, удлиняем её.
  function heredoc(path, body) {
    let tag = 'PMEOF';
    while (body.includes(tag)) tag += 'X';
    return 'cat > ' + path + " <<'" + tag + "'\n" + body.replace(/\n?$/, '\n') + tag;
  }

  function command(router, core, files) {
    if (!ROUTERS[router] || !ROUTERS[router].cores.includes(core)) throw new Error('Это сочетание роутера и ядра не поддерживается');
    const names = Object.keys(files);
    if (router === 'openwrt') {
      const parts = ['# OpenWrt: вставьте целиком в SSH-консоль роутера (нужен установленный Nikki)', 'mkdir -p ' + NIKKI_DIR];
      parts.push(heredoc(NIKKI_DIR + '/' + NIKKI_PROFILE, files['config.yaml']));
      parts.push("uci set nikki.config.profile='file:" + NIKKI_PROFILE + "'", "uci set nikki.config.enabled='1'", 'uci commit nikki', '/etc/init.d/nikki restart');
      return parts.join('\n') + '\n';
    }
    const dir = core === 'xray' ? '/opt/etc/xray/configs' : '/opt/etc/mihomo';
    const parts = ['# Keenetic: вставьте целиком в SSH-консоль роутера (Entware)',
      '# xkeen -' + core + '   – раскомментируйте, если сейчас работает другое ядро', 'mkdir -p ' + dir];
    names.forEach((n) => parts.push(heredoc(dir + '/' + n, files[n])));
    parts.push('xkeen -restart');
    return parts.join('\n') + '\n';
  }

  // Подписи для шага «Команда для роутера».
  function describe(router, core) {
    if (router === 'openwrt') return 'Запишет профиль в Nikki, включит его и перезапустит Nikki.';
    return 'Запишет ' + (core === 'xray' ? 'файлы' : 'конфиг') + ' и перезапустит XKeen.';
  }

  const api = { ROUTERS, CORES, NIKKI_PROFILE, NIKKI_DIR, routerCommand: command, routerDescribe: describe };
  if (typeof module === 'object' && module.exports) module.exports = api;
  root.PM = Object.assign(root.PM || {}, api);
})(typeof window !== 'undefined' ? window : globalThis);
