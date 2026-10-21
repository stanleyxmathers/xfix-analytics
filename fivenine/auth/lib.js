// Общие функции сервиса авторизации fivenine: хранилище пользователей, пароли, сессии.
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DATA_DIR = process.env.FIVENINE_DATA || '/etc/fivenine';
const USERS_FILE = path.join(DATA_DIR, 'users.json');
const TOOLS_FILE = path.join(DATA_DIR, 'tools.json');
const SECRET_FILE = path.join(DATA_DIR, 'secret');

const SESSION_DAYS = 30;

// Файлы перечитываются только при изменении mtime — правки через CLI подхватываются без рестарта.
const cache = new Map();
function readJson(file, fallback) {
  try {
    const { mtimeMs } = fs.statSync(file);
    const hit = cache.get(file);
    if (hit && hit.mtimeMs === mtimeMs) return hit.value;
    const value = JSON.parse(fs.readFileSync(file, 'utf8'));
    cache.set(file, { mtimeMs, value });
    return value;
  } catch (e) {
    if (e.code === 'ENOENT') return fallback;
    throw e;
  }
}

function writeJson(file, value) {
  const tmp = file + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2) + '\n', { mode: 0o640 });
  // Владелец как у каталога (root:fivenine), иначе сервис потеряет доступ на чтение.
  const dir = fs.statSync(path.dirname(file));
  try { fs.chownSync(tmp, dir.uid, dir.gid); } catch (e) { if (e.code !== 'EPERM') throw e; }
  fs.renameSync(tmp, file);
}

const loadUsers = () => readJson(USERS_FILE, {});
const saveUsers = (users) => writeJson(USERS_FILE, users);
const loadTools = () => readJson(TOOLS_FILE, []);

let secret;
function getSecret() {
  if (!secret) secret = fs.readFileSync(SECRET_FILE);
  return secret;
}

// ─── Пароли (scrypt) ─────────────────────────────────────────────────────────
function hashPassword(password) {
  const salt = crypto.randomBytes(16);
  const hash = crypto.scryptSync(password, salt, 64);
  return { salt: salt.toString('hex'), hash: hash.toString('hex') };
}

// Хэш-заглушка: сравнение выполняется и для несуществующего логина, чтобы время ответа не выдавало его.
const DUMMY = hashPassword(crypto.randomBytes(16).toString('hex'));

function verifyPassword(user, password) {
  const rec = user || DUMMY;
  const actual = crypto.scryptSync(password, Buffer.from(rec.salt, 'hex'), 64);
  const ok = crypto.timingSafeEqual(actual, Buffer.from(rec.hash, 'hex'));
  return ok && !!user;
}

// ─── Сессии: подписанный токен в cookie ──────────────────────────────────────
// В подпись входит фрагмент хэша пароля: смена пароля завершает все сессии пользователя.
const b64 = (s) => Buffer.from(s).toString('base64url');
const sign = (payload, user) =>
  crypto.createHmac('sha256', getSecret()).update(payload + '|' + user.hash.slice(0, 16)).digest('base64url');

function createSession(login, user) {
  const exp = Date.now() + SESSION_DAYS * 864e5;
  const payload = b64(JSON.stringify({ u: login, exp }));
  return { token: payload + '.' + sign(payload, user), maxAge: SESSION_DAYS * 86400 };
}

function readSession(token) {
  if (!token || typeof token !== 'string') return null;
  const [payload, sig] = token.split('.');
  if (!payload || !sig) return null;
  let data;
  try { data = JSON.parse(Buffer.from(payload, 'base64url').toString()); } catch { return null; }
  if (!data || typeof data.u !== 'string' || !(data.exp > Date.now())) return null;
  const user = loadUsers()[data.u];
  if (!user) return null;
  const expected = Buffer.from(sign(payload, user));
  const given = Buffer.from(sig);
  if (expected.length !== given.length || !crypto.timingSafeEqual(expected, given)) return null;
  return { login: data.u, user };
}

// ─── Доступ ──────────────────────────────────────────────────────────────────
const isAdmin = (user) => (user.access || []).includes('*');

function allowedTools(user) {
  const tools = loadTools();
  if (isAdmin(user)) return tools;
  const acc = new Set(user.access || []);
  return tools.filter((t) => acc.has(t.id));
}

// Путь, не принадлежащий ни одному инструменту, доступен только администратору.
const PUBLIC_FOR_USERS = ['/', '/index.html'];
const PUBLIC_PREFIXES = ['/profile/'];
// Инструмент с полным адресом (https://xfix.fivenine.space/roadmap/) совпадает только на своём хосте,
// с путём (/dashboard/) — по пути. Возвращает длину совпавшего пути, чтобы выбрать самый точный.
function matchTool(t, host, p) {
  if (!t.url) return -1;
  if (/^https?:\/\//.test(t.url)) {
    let u;
    try { u = new URL(t.url); } catch { return -1; }
    return u.host === host && p.startsWith(u.pathname) ? u.pathname.length : -1;
  }
  return p.startsWith(t.url) ? t.url.length : -1;
}

function canAccess(user, uri, host) {
  let p;
  try { p = decodeURIComponent(String(uri || '/').split('?')[0]); } catch { return false; }
  if (p.includes('..')) return false;
  if (PUBLIC_FOR_USERS.includes(p) || PUBLIC_PREFIXES.some((x) => p.startsWith(x))) return true;
  if (isAdmin(user)) return true;
  const h = String(host || '').toLowerCase();
  const tool = loadTools()
    .map((t) => ({ t, len: matchTool(t, h, p) }))
    .filter((x) => x.len >= 0)
    .sort((a, b) => b.len - a.len)[0];
  return !!tool && (user.access || []).includes(tool.t.id);
}

// ─── Профиль ─────────────────────────────────────────────────────────────────
const THEMES = ['light', 'dark', 'system'];
const DENSITIES = ['cozy', 'compact'];

// Приводим настройки к допустимым значениям: из браузера приходят чужие данные.
function cleanPrefs(input, current = {}) {
  const out = { ...current };
  if (!input || typeof input !== 'object') return out;
  if (THEMES.includes(input.theme)) out.theme = input.theme;
  if (DENSITIES.includes(input.density)) out.density = input.density;
  if (typeof input.greeting === 'boolean') out.greeting = input.greeting;
  if (Array.isArray(input.hidden)) {
    const known = new Set(loadTools().map((t) => t.id));
    out.hidden = [...new Set(input.hidden.filter((id) => typeof id === 'string' && known.has(id)))];
  }
  return out;
}

function cleanName(name) {
  if (typeof name !== 'string') return null;
  const v = name.replace(/[\u0000-\u001f\u007f]/g, '').replace(/\s+/g, ' ').trim();
  return v.length >= 1 && v.length <= 40 ? v : null;
}

// Изменение одного пользователя: свежее чтение, правка, атомарная запись.
function updateUser(login, change) {
  const users = JSON.parse(JSON.stringify(loadUsers()));
  if (!users[login]) return null;
  change(users[login]);
  saveUsers(users);
  return users[login];
}

module.exports = {
  cleanPrefs, cleanName, updateUser,
  DATA_DIR, USERS_FILE, TOOLS_FILE, SECRET_FILE,
  loadUsers, saveUsers, loadTools,
  hashPassword, verifyPassword,
  createSession, readSession,
  isAdmin, allowedTools, canAccess,
};
