// Сервис авторизации fivenine. Слушает только 127.0.0.1, снаружи доступен через nginx.
//   GET  /check   — для nginx auth_request: 204 / 401 / 403
//   GET  /login   — страница входа
//   POST /login   — проверка логина и пароля, выдача cookie
//   POST /logout  — выход
//   GET  /api/me  — текущий пользователь, его настройки и доступные инструменты
//   POST /api/profile  — имя и настройки панели
//   POST /api/password — смена пароля
'use strict';
const http = require('http');
const { URLSearchParams } = require('url');
const lib = require('./lib');

const PORT = +process.env.PORT || 4180;
const COOKIE = 'fn_session';
const COOKIE_DOMAIN = process.env.COOKIE_DOMAIN || '';

// ─── Ограничение попыток входа: 8 неудач за 15 минут с одного IP ────────────
const FAIL_LIMIT = 8;
const FAIL_WINDOW = 15 * 60e3;
const fails = new Map();
function tooManyFails(ip) {
  const rec = fails.get(ip);
  if (!rec || Date.now() - rec.first > FAIL_WINDOW) return false;
  return rec.count >= FAIL_LIMIT;
}
function noteFail(ip) {
  const rec = fails.get(ip);
  if (!rec || Date.now() - rec.first > FAIL_WINDOW) fails.set(ip, { first: Date.now(), count: 1 });
  else rec.count++;
}
setInterval(() => {
  const now = Date.now();
  for (const [ip, rec] of fails) if (now - rec.first > FAIL_WINDOW) fails.delete(ip);
}, FAIL_WINDOW).unref();

// ─── Утилиты ─────────────────────────────────────────────────────────────────
function getCookie(req, name) {
  const raw = req.headers.cookie || '';
  for (const part of raw.split(';')) {
    const i = part.indexOf('=');
    if (i > 0 && part.slice(0, i).trim() === name) return part.slice(i + 1).trim();
  }
  return null;
}

function cookieHeader(req, value, maxAge) {
  const secure = req.headers['x-forwarded-proto'] === 'https';
  return [
    `${COOKIE}=${value}`, 'Path=/', 'HttpOnly', 'SameSite=Lax', `Max-Age=${maxAge}`,
    secure && 'Secure', COOKIE_DOMAIN && `Domain=${COOKIE_DOMAIN}`,
  ].filter(Boolean).join('; ');
}

// Разрешаем возврат только на локальный путь — без открытого редиректа на чужой сайт.
function safeNext(next) {
  if (typeof next !== 'string' || !next.startsWith('/') || next.startsWith('//') || next.includes('\\')) return '/';
  if (next.startsWith('/login') || next.startsWith('/logout')) return '/';
  return next;
}

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function send(res, status, body, headers = {}) {
  res.writeHead(status, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Cache-Control': 'no-store',
    ...headers,
  });
  res.end(body);
}

function readBody(req, limit = 8192) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) { reject(new Error('too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString()));
    req.on('error', reject);
  });
}

const currentSession = (req) => lib.readSession(getCookie(req, COOKIE));

const json = (res, status, body, headers = {}) =>
  send(res, status, JSON.stringify(body), { 'Content-Type': 'application/json; charset=utf-8', ...headers });

function meBody(login, user) {
  return {
    login,
    name: user.name || login,
    admin: lib.isAdmin(user),
    prefs: user.prefs || {},
    tools: lib.allowedTools(user).map(({ id, title, desc, url, group, icon }) => ({ id, title, desc, url, group, icon })),
  };
}

// Изменяющие запросы принимаем только как JSON со своего сайта: форма с чужого сайта так не отправит.
async function readJsonBody(req, res) {
  const origin = req.headers.origin;
  if (origin) {
    let host;
    try { host = new URL(origin).host; } catch { host = null; }
    if (host !== req.headers.host) { json(res, 403, { error: 'forbidden' }); return null; }
  }
  if (!String(req.headers['content-type'] || '').startsWith('application/json')) { json(res, 415, { error: 'json only' }); return null; }
  try {
    const body = JSON.parse(await readBody(req));
    if (body && typeof body === 'object' && !Array.isArray(body)) return body;
  } catch { /* разберём ниже */ }
  json(res, 400, { error: 'bad json' });
  return null;
}

// ─── Страница входа ──────────────────────────────────────────────────────────
const MARK = (size) => `<svg class="brand-mark" width="${size}" height="${size}" viewBox="-2 1 96 96" aria-hidden="true">
  <circle cx="46" cy="40" r="22" fill="none" stroke="currentColor" stroke-width="9" stroke-linecap="round" stroke-dasharray="109.2 29" transform="rotate(-12.2 46 40)"/>
  <path d="M68 40 V54 C68 70 58 80 42 80" fill="none" stroke="currentColor" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"/>
  <circle class="moon" cx="60.14" cy="23.15" r="6"/>
</svg>`;

function loginPage({ next = '/', error = '', login = '' } = {}) {
  return `<!doctype html>
<html lang="ru"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Вход · fivenine.space</title>
<link rel="icon" href="/_assets/favicon.svg" type="image/svg+xml">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Geologica:wght@300..700&family=Onest:wght@400..700&display=swap" rel="stylesheet">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@fontsource/golos-ui@4.5.3/500.css"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@fontsource/golos-ui@4.5.3/600.css">
<link rel="stylesheet" href="/_assets/fivenine.css">
<script src="/_assets/theme.js"></script>
<style>
  .wrap { position: relative; z-index: 1; min-height: 100vh; display: grid; place-items: center; padding: 24px 16px; }
  .card { width: 100%; max-width: 400px; padding: 32px 28px 26px; display: grid; gap: 24px; overflow: hidden; }
  .head { position: relative; display: grid; gap: 22px; }
  h1 { font-family: var(--font-display); font-size: 28px; font-weight: 600; line-height: 1.15; letter-spacing: -0.02em; }
  form { display: grid; gap: 14px; }
  .btn { margin-top: 8px; width: 100%; }
  .foot { display: flex; justify-content: center; }
  .backdrop .orbits { right: auto; left: 50%; top: 50%; width: 900px; height: 900px; transform: translate(-50%, -50%); }
</style>
</head><body>
<div class="backdrop" aria-hidden="true">
  <div class="orb orb-1"></div><div class="orb orb-2"></div><div class="orb orb-3"></div>
  <svg class="orbits" viewBox="0 0 720 720">
    <circle class="ring" cx="360" cy="360" r="230"/><circle class="ring" cx="360" cy="360" r="300"/>
    <circle class="ring" cx="360" cy="360" r="355" stroke-dasharray="2 8"/>
    <circle class="moon" cx="572" cy="245" r="6"/><circle class="moon" cx="150" cy="520" r="4" opacity="0.6"/>
  </svg>
</div>
<main class="wrap">
  <section class="card glass">
    <div class="head">
      <div class="brand">${MARK(38)}<span class="wordmark"><b>fivenine</b><i>.</i><span>space</span></span></div>
      <h1>Вход</h1>
    </div>
    ${error ? `<div class="alert" role="alert">${esc(error)}</div>` : ''}
    <form method="post" action="/login" autocomplete="on">
      <input type="hidden" name="next" value="${esc(next)}">
      <div class="field">
        <label for="login">Логин</label>
        <input class="input" id="login" name="login" autocomplete="username" autocapitalize="none" spellcheck="false" required value="${esc(login)}" ${login ? '' : 'autofocus'}>
      </div>
      <div class="field">
        <label for="password">Пароль</label>
        <input class="input" id="password" name="password" type="password" autocomplete="current-password" required ${login ? 'autofocus' : ''}>
      </div>
      <button class="btn" type="submit">Войти</button>
    </form>
    <div class="foot">
      <span class="dots" aria-hidden="true"><span></span><span></span><span></span><span></span><span></span></span>
    </div>
  </section>
</main>
</body></html>`;
}

const HTML = { 'Content-Type': 'text/html; charset=utf-8' };

// ─── Маршруты ────────────────────────────────────────────────────────────────
async function handle(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const ip = req.headers['x-real-ip'] || req.socket.remoteAddress;

  if (url.pathname === '/check') {
    const s = currentSession(req);
    if (!s) return send(res, 401, '');
    if (!lib.canAccess(s.user, req.headers['x-original-uri'], req.headers['x-original-host'])) return send(res, 403, '');
    return send(res, 204, '', { 'X-Auth-User': s.login });
  }

  if (url.pathname === '/login' && req.method === 'GET') {
    const next = safeNext(url.searchParams.get('next'));
    if (currentSession(req)) return send(res, 303, '', { Location: next });
    return send(res, 200, loginPage({ next }), HTML);
  }

  if (url.pathname === '/login' && req.method === 'POST') {
    let form;
    try { form = new URLSearchParams(await readBody(req)); } catch { return send(res, 413, ''); }
    const login = (form.get('login') || '').trim().toLowerCase();
    const password = form.get('password') || '';
    const next = safeNext(form.get('next'));

    if (tooManyFails(ip)) {
      return send(res, 429, loginPage({ next, login, error: 'Слишком много попыток. Попробуйте через 15 минут.' }), HTML);
    }
    const user = lib.loadUsers()[login];
    if (!login || !password || !lib.verifyPassword(user, password)) {
      noteFail(ip);
      console.log(`login fail user=${JSON.stringify(login)} ip=${ip}`);
      return send(res, 401, loginPage({ next, login, error: 'Неверный логин или пароль' }), HTML);
    }
    fails.delete(ip);
    console.log(`login ok user=${login} ip=${ip}`);
    const { token, maxAge } = lib.createSession(login, user);
    return send(res, 303, '', { Location: next, 'Set-Cookie': cookieHeader(req, token, maxAge) });
  }

  if (url.pathname === '/logout' && req.method === 'POST') {
    return send(res, 303, '', { Location: '/login', 'Set-Cookie': cookieHeader(req, '', 0) });
  }

  if (url.pathname === '/api/me') {
    const s = currentSession(req);
    if (!s) return json(res, 401, {});
    return json(res, 200, meBody(s.login, s.user));
  }

  if (url.pathname === '/api/profile' && req.method === 'POST') {
    const s = currentSession(req);
    if (!s) return json(res, 401, {});
    const body = await readJsonBody(req, res);
    if (!body) return;
    let name;
    if (body.name !== undefined) {
      name = lib.cleanName(body.name);
      if (!name) return json(res, 400, { error: 'Имя: от 1 до 40 символов' });
    }
    const user = lib.updateUser(s.login, (u) => {
      if (name) u.name = name;
      if (body.prefs !== undefined) u.prefs = lib.cleanPrefs(body.prefs, u.prefs);
    });
    if (!user) return json(res, 401, {});
    return json(res, 200, meBody(s.login, user));
  }

  if (url.pathname === '/api/password' && req.method === 'POST') {
    const s = currentSession(req);
    if (!s) return json(res, 401, {});
    if (tooManyFails(ip)) return json(res, 429, { error: 'Слишком много попыток. Попробуйте через 15 минут.' });
    const body = await readJsonBody(req, res);
    if (!body) return;
    const current = typeof body.current === 'string' ? body.current : '';
    const next = typeof body.next === 'string' ? body.next : '';
    if (!lib.verifyPassword(s.user, current)) {
      noteFail(ip);
      console.log(`password change fail user=${s.login} ip=${ip}`);
      return json(res, 400, { error: 'Текущий пароль неверный' });
    }
    if (next.length < 8 || next.length > 200) return json(res, 400, { error: 'Новый пароль: не короче 8 символов' });
    if (next === current) return json(res, 400, { error: 'Новый пароль совпадает с текущим' });
    const user = lib.updateUser(s.login, (u) => Object.assign(u, lib.hashPassword(next)));
    console.log(`password changed user=${s.login} ip=${ip}`);
    // Смена пароля завершает все сессии; текущему устройству выдаём новую.
    const { token, maxAge } = lib.createSession(s.login, user);
    return json(res, 200, { ok: true }, { 'Set-Cookie': cookieHeader(req, token, maxAge) });
  }

  return send(res, 404, 'Not found');
}

http.createServer((req, res) => {
  handle(req, res).catch((e) => {
    console.error(e);
    if (!res.headersSent) send(res, 500, 'Internal error');
  });
}).listen(PORT, '127.0.0.1', () => console.log(`fivenine-auth listening on 127.0.0.1:${PORT}`));
