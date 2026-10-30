#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVFILE="$HERE/.env"
command -v docker >/dev/null 2>&1 || { echo 'Install Docker first.' >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo 'Docker Compose v2 is required.' >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo 'Install openssl first.' >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo 'Docker daemon unavailable or access denied.' >&2; exit 1; }

if [[ ! -f "$ENVFILE" ]]; then
  echo 'XRIXUID + Telegram Bot Cloud Setup'
  echo 'DNS: point your chosen domain A record to this VPS public IP first.'
  read -r -p 'Domain (e.g. operator.example.com): ' DOMAIN
  [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ && "$DOMAIN" == *.* ]] || { echo 'Invalid domain.' >&2; exit 1; }
  read -r -p 'Web login username [admin]: ' WEB_USER
  WEB_USER="${WEB_USER:-admin}"
  [[ "$WEB_USER" =~ ^[A-Za-z0-9_-]+$ ]] || { echo 'Invalid username.' >&2; exit 1; }
  read -r -s -p 'Telegram bot token (@BotFather; input hidden): ' TG_BOT_TOKEN
  echo
  read -r -p 'Your numeric Telegram owner ID: ' TG_OWNER_ID
  [[ "$TG_BOT_TOKEN" =~ ^[0-9]{5,}:[A-Za-z0-9_-]{20,}$ ]] || { echo 'Invalid bot token.' >&2; exit 1; }
  [[ "$TG_OWNER_ID" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid owner ID.' >&2; exit 1; }
  WEB_PASS="$(openssl rand -hex 14)"
  WEB_HASH="$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$WEB_PASS")"
  DB_PASSWORD="$(openssl rand -hex 24)"
  ADMIN_KEY="$(openssl rand -hex 24)"
  CONTROL_TOKEN="$(openssl rand -hex 32)"
  umask 077
  {
    printf 'DOMAIN=%s\n' "$DOMAIN"
    printf 'WEB_USER=%s\n' "$WEB_USER"
    printf "WEB_HASH='%s'\n" "$WEB_HASH"
    printf 'DB_PASSWORD=%s\n' "$DB_PASSWORD"
    printf 'ADMIN_KEY=%s\n' "$ADMIN_KEY"
    printf 'CONTROL_TOKEN=%s\n' "$CONTROL_TOKEN"
    printf 'TG_BOT_TOKEN=%s\n' "$TG_BOT_TOKEN"
    printf 'TG_OWNER_ID=%s\n' "$TG_OWNER_ID"
  } > "$ENVFILE"
  chmod 600 "$ENVFILE"
  echo
  echo 'IMPORTANT: save these web login credentials privately.'
  echo "Domain: https://$DOMAIN"
  echo "Username: $WEB_USER"
  echo "Password: $WEB_PASS"
  echo 'The password is displayed only during initial setup.'
  unset WEB_PASS WEB_HASH DB_PASSWORD ADMIN_KEY CONTROL_TOKEN TG_BOT_TOKEN
else
  echo 'Using existing cloud/.env without changing stored credentials.'
fi

docker compose --env-file "$ENVFILE" -f "$HERE/compose.yaml" config --quiet
docker compose --env-file "$ENVFILE" -f "$HERE/compose.yaml" up -d --build
echo
echo 'All services have been launched. Check live health using:'
echo "docker compose --env-file '$ENVFILE' -f '$HERE/compose.yaml' ps"
echo "docker compose --env-file '$ENVFILE' -f '$HERE/compose.yaml' logs --tail=60 app bot web"
echo 'In Telegram, open your bot and send /start.'
