// Общая оболочка страниц fivenine: фон, боковая панель, тема, данные пользователя.
// Страница кладёт <aside id="sidebar"> и ждёт FN.ready → объект /api/me.
(function () {
  const ICONS = {
    home: '<path d="M4 11l8-7 8 7v9a1 1 0 0 1-1 1h-4v-6h-6v6H5a1 1 0 0 1-1-1z"/>',
    profile: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
    chart: '<path d="M5 20v-6M12 20V6M19 20v-9"/>',
    table: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M9 4v16"/>',
    calendar: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>',
    doc: '<path d="M6 3h9l4 4v14H6zM15 3v4h4M9 12h6M9 16h6"/>',
    wallet: '<rect x="3" y="6" width="18" height="14" rx="2"/><path d="M3 10h18M16 15h2"/>',
    user: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
    mail: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 7l9 6 9-6"/>',
    copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h3"/>',
    bolt:'<path d="M13 3L5 14h6l-1 7 8-11h-6z"/>',
    heart: '<path d="M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.6-7 10-7 10z"/>',
    bot: '<path d="M12 4v3M7 8h10a3 3 0 0 1 3 3v5a3 3 0 0 1-3 3H7a3 3 0 0 1-3-3v-5a3 3 0 0 1 3-3zM9.5 13v1M14.5 13v1"/>',
    tool: '<path d="M14.7 6.3a4 4 0 0 0-5.4 5.4L3 18l3 3 6.3-6.3a4 4 0 0 0 5.4-5.4l-2.6 2.6-2.4-.6-.6-2.4z"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    moon: '<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/>',
    logout: '<path d="M15 4h3a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3M10 17l5-5-5-5M15 12H4"/>',
  };
  const svg = (k, s = 20) => `<svg width="${s}" height="${s}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONS[k] || ICONS.tool}</svg>`;
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const DOTS = '<span></span><span></span><span></span><span></span><span></span>';

  function plural(n, one, few, many) {
    const m10 = n % 10, m100 = n % 100;
    if (m10 === 1 && m100 !== 11) return one;
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
    return many;
  }

  function groupBy(tools) {
    const groups = new Map();
    for (const t of tools) {
      const g = t.group || 'Разное';
      if (!groups.has(g)) groups.set(g, []);
      groups.get(g).push(t);
    }
    return groups;
  }

  // ─── Тема ──────────────────────────────────────────────────────────────────
  const media = window.matchMedia ? matchMedia('(prefers-color-scheme: dark)') : null;
  let themePref = 'light';
  try { themePref = localStorage.getItem('fn-theme') || localStorage.getItem('xfix-theme') || 'light'; } catch (e) {}

  function applyTheme(pref) {
    themePref = pref;
    const t = pref === 'dark' || (pref === 'system' && media && media.matches) ? 'dark' : 'light';
    document.documentElement.dataset.theme = t;
    try { localStorage.setItem('fn-theme', pref); localStorage.setItem('xfix-theme', t); } catch (e) {}
    const btn = document.getElementById('theme-btn');
    if (btn) btn.innerHTML = svg(t === 'dark' ? 'sun' : 'moon', 18);
    document.dispatchEvent(new CustomEvent('fn:theme', { detail: pref }));
  }
  if (media) media.addEventListener('change', () => { if (themePref === 'system') applyTheme('system'); });

  function applyPrefs(prefs) {
    prefs = prefs || {};
    if (prefs.theme) applyTheme(prefs.theme);
    document.documentElement.dataset.density = prefs.density || 'cozy';
  }

  // ─── API ───────────────────────────────────────────────────────────────────
  async function api(path, body) {
    const r = await fetch(path, {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (r.status === 401) { location.href = '/login?next=' + encodeURIComponent(location.pathname); throw new Error('auth'); }
    const data = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(data.error || 'Не удалось сохранить');
    return data;
  }

  async function savePrefs(patch) {
    const me = await api('/api/profile', { prefs: patch });
    FN.me = me;
    return me;
  }

  // ─── Фон и боковая панель ──────────────────────────────────────────────────
  const BACKDROP = `<div class="backdrop" aria-hidden="true">
    <div class="orb orb-1"></div><div class="orb orb-2"></div><div class="orb orb-3"></div>
    <svg class="orbits" viewBox="0 0 720 720">
      <circle class="ring" cx="360" cy="360" r="170"/><circle class="ring" cx="360" cy="360" r="270"/>
      <circle class="ring" cx="360" cy="360" r="350" stroke-dasharray="2 8"/>
      <circle class="moon" cx="214" cy="470" r="6"/><circle class="moon" cx="560" cy="170" r="4" opacity="0.6"/>
    </svg></div>`;

  const MARK = `<svg class="brand-mark" width="38" height="38" viewBox="-2 1 96 96" aria-hidden="true">
    <circle cx="46" cy="40" r="22" fill="none" stroke="currentColor" stroke-width="9" stroke-linecap="round" stroke-dasharray="109.2 29" transform="rotate(-12.2 46 40)"/>
    <path d="M68 40 V54 C68 70 58 80 42 80" fill="none" stroke="currentColor" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"/>
    <circle class="moon" cx="60.14" cy="23.15" r="6"/></svg>`;

  const path = location.pathname;
  const isActive = (href) => (href === '/' ? path === '/' || path === '/index.html' : path.startsWith(href));
  const navLink = (href, icon, title) =>
    `<a href="${esc(href)}" title="${esc(title)}"${isActive(href) ? ' class="active" aria-current="page"' : ''}>${svg(icon)}<span>${esc(title)}</span></a>`;

  function renderSidebar(me) {
    const el = document.getElementById('sidebar');
    if (!el) return;
    const tools = me ? me.tools : [];
    const groups = [...groupBy(tools)].map(([g, list]) =>
      `<div class="label">${esc(g)}</div>` + list.map((t) => navLink(t.url, t.icon, t.title)).join('')).join('');
    const n = tools.length;
    const name = me ? me.name : '';
    el.innerHTML = `
      <a class="brand" href="/" aria-label="fivenine.space — главная">${MARK}<span class="wordmark"><b>fivenine</b><i>.</i><span>space</span></span></a>
      <nav class="nav" aria-label="Разделы">${navLink('/', 'home', 'Главная')}${groups}${me && me.admin ? `<div class="label">Управление</div>${navLink('/invites/', 'mail', 'Приглашения')}` : ''}</nav>
      <div class="side-foot">
        <div class="status">
          <span class="dots${me ? '' : ' loading'}">${DOTS}</span>
          <span class="status-text">${me ? (n ? `${n} ${plural(n, 'инструмент', 'инструмента', 'инструментов')} на связи` : 'Инструментов пока нет') : 'Загружаем…'}</span>
        </div>
        <div class="me">
          <a class="me-link${isActive('/profile/') ? ' active' : ''}" href="/profile/" title="Профиль">
            <span class="avatar">${esc(name.slice(0, 1).toUpperCase())}</span>
            <span class="me-name">${esc(name)}</span>
          </a>
          <button class="btn btn-ghost btn-icon" id="theme-btn" type="button" title="Сменить тему" aria-label="Сменить тему"></button>
          <form method="post" action="/logout"><button class="btn btn-ghost btn-icon" type="submit" title="Выйти" aria-label="Выйти">${svg('logout', 18)}</button></form>
        </div>
      </div>`;
    const btn = document.getElementById('theme-btn');
    btn.innerHTML = svg(document.documentElement.dataset.theme === 'dark' ? 'sun' : 'moon', 18);
    btn.addEventListener('click', () => {
      const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
      applyTheme(next);
      if (FN.me) savePrefs({ theme: next }).catch(() => {});
    });
  }

  function refreshMe(me) {
    FN.me = me;
    renderSidebar(me);
  }

  window.FN = { ICONS, svg, esc, plural, groupBy, api, savePrefs, applyTheme, applyPrefs, refreshMe, me: null };

  document.body.insertAdjacentHTML('afterbegin', BACKDROP);
  renderSidebar(null);

  FN.ready = fetch('/api/me', { credentials: 'same-origin' })
    .then((r) => {
      if (r.status === 401) { location.href = '/login?next=' + encodeURIComponent(location.pathname); throw new Error('auth'); }
      return r.json();
    })
    .then((me) => { applyPrefs(me.prefs); refreshMe(me); return me; });
})();
