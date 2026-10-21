#!/usr/bin/env bash
# Выкладывает fivenine на сервер: ./fivenine/deploy.sh
# Пользователи (/etc/fivenine/users.json) и список инструментов (/etc/fivenine/tools.json) не перезаписываются.
set -euo pipefail
SERVER="root@201.51.26.78"
DIR="$(cd "$(dirname "$0")" && pwd)"

ssh "$SERVER" 'mkdir -p /opt/fivenine/auth /var/www/tools/_assets /etc/fivenine'
scp -q "$DIR/auth/lib.js" "$DIR/auth/server.js" "$DIR/auth/cli.js" "$SERVER:/opt/fivenine/auth/"
scp -q "$DIR/auth/fivenine-auth.service" "$SERVER:/etc/systemd/system/fivenine-auth.service"
scp -q "$DIR/site/index.html" "$SERVER:/var/www/tools/index.html"
ssh "$SERVER" 'mkdir -p /var/www/tools/profile /var/www/tools/invites'
scp -q "$DIR/site/profile/index.html" "$SERVER:/var/www/tools/profile/index.html"
scp -q "$DIR/site/invites/index.html" "$SERVER:/var/www/tools/invites/index.html"
scp -q "$DIR/site/_assets/"* "$SERVER:/var/www/tools/_assets/"
scp -q "$DIR/nginx/fivenine.conf" "$SERVER:/etc/nginx/sites-available/fivenine"
scp -q "$DIR/tools.example.json" "$SERVER:/tmp/fivenine-tools.example.json"

ssh "$SERVER" bash -s <<'REMOTE'
set -euo pipefail
id fivenine >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin fivenine
[ -f /etc/fivenine/secret ] || head -c 48 /dev/urandom > /etc/fivenine/secret
[ -f /etc/fivenine/tools.json ] || cp /tmp/fivenine-tools.example.json /etc/fivenine/tools.json
[ -f /etc/fivenine/users.json ] || echo '{}' > /etc/fivenine/users.json
rm -f /tmp/fivenine-tools.example.json
chown -R root:fivenine /etc/fivenine
# Сервис пишет users.json (профиль): каталог доступен группе на запись, secret — только на чтение.
chmod 770 /etc/fivenine
chmod 660 /etc/fivenine/users.json
chmod 640 /etc/fivenine/secret /etc/fivenine/tools.json
chmod -R a+rX /var/www/tools /opt/fivenine
ln -sf /opt/fivenine/auth/cli.js /usr/local/bin/fivenine
chmod 755 /opt/fivenine/auth/cli.js
systemctl daemon-reload
systemctl enable --now fivenine-auth >/dev/null 2>&1
systemctl restart fivenine-auth
ln -sf /etc/nginx/sites-available/fivenine /etc/nginx/sites-enabled/fivenine
rm -f /etc/nginx/sites-enabled/tools
nginx -t
systemctl reload nginx
REMOTE
echo "Готово"
