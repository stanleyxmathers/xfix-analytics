#!/usr/bin/env bash
# Публикует дашборд на сервер: ./deploy.sh
set -euo pipefail
SERVER="root@201.51.26.78"
ssh "$SERVER" mkdir -p /var/www/xfix/analytics
scp -q "$(dirname "$0")/dashboard.html" "$SERVER:/var/www/xfix/analytics/index.html"
ssh "$SERVER" chmod 644 /var/www/xfix/analytics/index.html
echo "Готово: https://xfix.fivenine.space/analytics/"
