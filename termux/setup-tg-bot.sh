#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

RAW="https://raw.githubusercontent.com/parvez-devs/uidhub/main/termux/xrixuid-tg-bot.py"
BOT="$HOME/xrixuid-tg-bot.py"
CONF="$HOME/.xrixuid-tg.env"

command -v pkg >/dev/null || { echo 'Run this in normal Termux, not Debian.' >&2; exit 1; }
pkg install -y python tmux curl ca-certificates

echo '[XRIXUID-TG] Downloading controller...'
curl -fLsS --retry 3 "$RAW" -o "$BOT.tmp"
python3 -m py_compile "$BOT.tmp"
mv -f "$BOT.tmp" "$BOT"
chmod 700 "$BOT"

if [ ! -s "$CONF" ]; then
  echo
  echo 'Create a NEW Telegram bot with @BotFather and copy the token.'
  echo 'Find YOUR numeric Telegram user ID (not username).'
  read -r -s -p 'Telegram bot token (hidden): ' BOT_TOKEN
  echo
  read -r -p 'Your numeric Telegram user ID: ' OWNER_ID
  if [[ ! "$BOT_TOKEN" =~ ^[0-9]{5,}:[A-Za-z0-9_-]{20,}$ ]]; then
    echo 'Invalid bot token format.' >&2; exit 1
  fi
  if [[ ! "$OWNER_ID" =~ ^[1-9][0-9]*$ ]]; then
    echo 'Invalid numeric Telegram ID.' >&2; exit 1
  fi
  umask 077
  printf 'TG_BOT_TOKEN=%s\nTG_OWNER_ID=%s\n' "$BOT_TOKEN" "$OWNER_ID" > "$CONF"
  chmod 600 "$CONF"
  unset BOT_TOKEN OWNER_ID
else
  echo '[XRIXUID-TG] Using saved local bot credentials.'
fi

if [ ! -f "$HOME/xrixuid-termux.sh" ]; then
  echo '[XRIXUID-TG] Missing XRIXUID launcher.' >&2
  echo 'Install XRIXUID first: bash ~/xrixuid-termux.sh install' >&2
  exit 1
fi

if tmux has-session -t xrixuid-tg 2>/dev/null; then
  echo '[XRIXUID-TG] Restarting previous controller session.'
  tmux kill-session -t xrixuid-tg
fi

touch "$HOME/xrixuid-tg-bot.log"
chmod 600 "$HOME/xrixuid-tg-bot.log"
tmux new-session -d -s xrixuid-tg \
  "python3 '$BOT' >> '$HOME/xrixuid-tg-bot.log' 2>&1"

sleep 2
if tmux has-session -t xrixuid-tg 2>/dev/null; then
  echo
  echo '✅ Telegram controller launched.'
  echo 'Open your bot in Telegram and type /start.'
  echo 'Options: /run /stop /status /logs'
  echo
  echo 'Controller status: tmux has-session -t xrixuid-tg'
  echo 'Controller logs: tail -n 30 ~/xrixuid-tg-bot.log'
  echo 'Controller stop: tmux kill-session -t xrixuid-tg'
else
  echo '[XRIXUID-TG] Controller exited early. Check logs:' >&2
  tail -n 30 "$HOME/xrixuid-tg-bot.log" >&2
  exit 1
fi
