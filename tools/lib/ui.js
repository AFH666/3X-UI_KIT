// Общие элементы интерфейса генераторов.
(function (root) {
  'use strict';
  const $ = (s, el) => (el || document).querySelector(s);
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  const store = {
    get(k) { try { return localStorage.getItem('pm:' + k); } catch (e) { return null; } },
    set(k, v) { try { localStorage.setItem('pm:' + k, v); } catch (e) { /* приватный режим */ } },
  };

  function renderParsed(el, parsed, skipped) {
    const sk = {};
    (skipped || []).forEach((s) => { sk[s.name] = s.error; });
    const chips = parsed.proxies.map((p) => {
      const why = sk[p.name];
      return '<span class="chip' + (why ? ' skip' : '') + '" title="' + esc(why || p.server + ':' + p.port) + '">' +
        '<span class="p">' + esc(p.type === 'hysteria2' ? 'hy2' : p.type) + '</span>' + esc(p.name) +
        '<span class="s">' + esc(why ? 'пропущен: ' + why : p.server + ':' + p.port) + '</span></span>';
    });
    parsed.errors.forEach((e) => {
      chips.push('<span class="chip bad" title="' + esc(e.text) + '"><span class="p">ошибка</span>строка ' + e.line +
        '<span class="s">' + esc(e.error) + '</span></span>');
    });
    el.innerHTML = chips.join('');
  }

  function tabs(el, onChange) {
    el.addEventListener('click', (e) => {
      const b = e.target.closest('button[data-tab]');
      if (!b) return;
      el.querySelectorAll('button').forEach((x) => x.classList.toggle('on', x === b));
      onChange(b.dataset.tab);
    });
  }

  async function copy(text, btn) {
    try {
      await navigator.clipboard.writeText(text);
    } catch (e) {
      const t = document.createElement('textarea');
      t.value = text; document.body.appendChild(t); t.select(); document.execCommand('copy'); t.remove();
    }
    const old = btn.textContent;
    btn.textContent = 'Скопировано ✓';
    setTimeout(() => { btn.textContent = old; }, 1600);
  }

  function download(name, text) {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([text], { type: 'text/plain;charset=utf-8' }));
    a.download = name;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }

  root.UI = { $, esc, store, renderParsed, tabs, copy, download };
})(window);
