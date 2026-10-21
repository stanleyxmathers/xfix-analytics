#!/usr/bin/env node
// Управление пользователями fivenine (запускать на сервере от root):
//   fivenine user add <login> [--name "Имя"] [--access id1,id2 | --access "*"]
//   fivenine user passwd <login>
//   fivenine user access <login> <id1,id2 | *>
//   fivenine user del <login>
//   fivenine user list
//   fivenine tools
//   fivenine invite [login] [--name "Имя"] [--access id1,id2] [--days 7]  — ссылка-приглашение
//   fivenine invite list | fivenine invite del <id>
'use strict';
const readline = require('readline');
const lib = require('./lib');

function fail(msg) { console.error(msg); process.exit(1); }

function opt(args, name) {
  const i = args.indexOf(name);
  if (i < 0) return undefined;
  const v = args[i + 1];
  args.splice(i, 2);
  return v;
}

const parseAccess = (s) => String(s).split(',').map((x) => x.trim()).filter(Boolean);

// Ввод пароля без отображения символов.
function askHidden(question) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true });
    rl.stdoutMuted = false;
    rl._writeToOutput = (s) => { if (!rl.stdoutMuted) rl.output.write(s); };
    rl.question(question, (answer) => { rl.close(); process.stdout.write('\n'); resolve(answer); });
    rl.stdoutMuted = true;
  });
}

async function askNewPassword() {
  const p1 = await askHidden('Пароль: ');
  if (p1.length < 8) fail('Пароль должен быть не короче 8 символов');
  const p2 = await askHidden('Повторите пароль: ');
  if (p1 !== p2) fail('Пароли не совпадают');
  return p1;
}

function checkToolIds(access) {
  const known = new Set(lib.loadTools().map((t) => t.id));
  const unknown = access.filter((a) => a !== '*' && !known.has(a));
  if (unknown.length) fail(`Нет таких инструментов: ${unknown.join(', ')}. Список: fivenine tools`);
}

async function main() {
  const args = process.argv.slice(2);
  const [scope, cmd, login] = args;
  const users = lib.loadUsers();

  if (scope === 'tools') {
    for (const t of lib.loadTools()) console.log(`${t.id.padEnd(20)} ${t.url.padEnd(20)} ${t.title}`);
    return;
  }
  if (scope === 'invite') {
    const rest = args.slice(1);
    if (rest[0] === 'list') {
      for (const i of lib.listInvites()) {
        console.log(`${i.id}  ${i.status.padEnd(8)} ${(i.login || '(любой)').padEnd(16)} ${i.access.join(',').padEnd(24)} до ${i.exp.slice(0, 10)}${i.usedBy ? `  → ${i.usedBy}` : ''}`);
      }
      return;
    }
    if (rest[0] === 'del') {
      if (!lib.revokeInvite(rest[1] || '')) fail('Нет такого приглашения. Список: fivenine invite list');
      console.log('Приглашение отозвано');
      return;
    }
    const name = opt(rest, '--name') || null;
    const access = parseAccess(opt(rest, '--access') || '');
    const days = opt(rest, '--days');
    const login = rest[0] || null;
    checkToolIds(access);
    const { token } = lib.createInvite({ login, name, access, days, by: 'cli' });
    console.log(`${lib.inviteTarget(access).base}/invite?t=${token}`);
    return;
  }
  if (scope !== 'user') fail('Использование: fivenine user add|passwd|access|del|list … | fivenine tools');

  if (cmd === 'list') {
    for (const [l, u] of Object.entries(users)) console.log(`${l.padEnd(16)} ${(u.name || '').padEnd(20)} ${(u.access || []).join(',')}`);
    return;
  }

  if (!login || !/^[a-z0-9._-]{2,32}$/.test(login)) fail('Логин: 2–32 символа, латиница в нижнем регистре, цифры, . _ -');

  if (cmd === 'add') {
    if (users[login]) fail(`Пользователь ${login} уже есть`);
    const rest = args.slice(3);
    const name = opt(rest, '--name') || login;
    const access = parseAccess(opt(rest, '--access') || '');
    checkToolIds(access);
    users[login] = { name, ...lib.hashPassword(await askNewPassword()), access };
    lib.saveUsers(users);
    console.log(`Добавлен ${login}, доступ: ${access.join(',') || 'только главная'}`);
  } else if (cmd === 'passwd') {
    if (!users[login]) fail(`Нет пользователя ${login}`);
    Object.assign(users[login], lib.hashPassword(await askNewPassword()));
    lib.saveUsers(users);
    console.log(`Пароль ${login} изменён, старые сессии завершены`);
  } else if (cmd === 'access') {
    if (!users[login]) fail(`Нет пользователя ${login}`);
    const access = parseAccess(args[3] || '');
    checkToolIds(access);
    users[login].access = access;
    lib.saveUsers(users);
    console.log(`Доступ ${login}: ${access.join(',') || 'только главная'}`);
  } else if (cmd === 'del') {
    if (!users[login]) fail(`Нет пользователя ${login}`);
    delete users[login];
    lib.saveUsers(users);
    console.log(`Удалён ${login}`);
  } else {
    fail('Неизвестная команда');
  }
}

main().catch((e) => fail(e.message));
