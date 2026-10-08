#!/usr/bin/env bash
# Публикует дашборд на сервер: ./deploy.sh
set -euo pipefail
SERVER="root@201.51.26.78"
scp -q "$(dirname "$0")/dashboard.html" "$SERVER:/var/www/tools/dashboard/index.html"
ssh "$SERVER" chmod 644 /var/www/tools/dashboard/index.html
echo "Готово: https://fivenine.space/dashboard/"
