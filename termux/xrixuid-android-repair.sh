#!/data/data/com.termux/files/usr/bin/bash
# Standalone recovery for XRIXUID on Android. Does not alter original GitHub installer.
set -Eeuo pipefail
MODE="${1:-repair}"
ROOT="$HOME/projects/xrixuid"
LOG="$HOME/xrixuid-single.log"
SESSION="xrixuid-single"
msg(){ printf '[XRIXUID REPAIR] %s\n' "$*"; }
err(){ printf '[XRIXUID REPAIR] ERROR: %s\n' "$*" >&2; exit 1; }
command -v pkg >/dev/null 2>&1 || err 'Run from normal Termux ($), not Debian (root@localhost).'
[ -f "$ROOT/package.json" ] || err "Project not found: $ROOT"

if [[ "$MODE" == status ]]; then
    if tmux has-session -t "$SESSION" 2>/dev/null; then
        msg 'Unified API + Frontend session: running'
    else
        msg 'Unified API + Frontend session: stopped'
    fi
    for port in 3000 8080; do
        printf 'Port %s: ' "$port"
        curl -sS -m 3 -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:$port/" || true
    done
    exit 0
elif [[ "$MODE" == logs ]]; then
    tail -n 70 "$LOG" 2>/dev/null || true
    exit 0
elif [[ "$MODE" == stop ]]; then
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    msg 'Unified session stopped. Database untouched.'
    exit 0
elif [[ "$MODE" != repair && "$MODE" != start ]]; then
    err 'Usage: repair | start | stop | status | logs'
fi

pkg install -y proot-distro tmux curl openssl postgresql >/dev/null
termux-wake-lock 2>/dev/null || true
PGDATA="$PREFIX/var/lib/postgresql"
mkdir -p "$PGDATA"
[ -f "$PGDATA/PG_VERSION" ] || initdb -D "$PGDATA"
pg_ctl -D "$PGDATA" status >/dev/null 2>&1 || pg_ctl -D "$PGDATA" -l "$HOME/xrixuid-postgres.log" -o '-h 127.0.0.1' start
if [ ! -s "$ROOT/.xrixuid.env" ]; then
    export PGHOST=127.0.0.1 PGUSER="$(whoami)"
    [ "$(psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='uid_operator'" | tr -d '[:space:]')" = 1 ] || createdb uid_operator
    umask 077
    printf "export DATABASE_URL='postgresql://%s@127.0.0.1:5432/uid_operator'\nexport ADMIN_KEY='%s'\nexport BASE_PATH=/\n" "$PGUSER" "$(openssl rand -hex 24)" > "$ROOT/.xrixuid.env"
    chmod 600 "$ROOT/.xrixuid.env"
fi

# Store nvm inside the project so --shared-home and /root resolve identically.
cat > "$ROOT/.xrixuid-single-ensure-node.sh" <<'INNER'
#!/bin/bash
set -Eeuo pipefail
PROJECT="/data/data/com.termux/files/home/projects/xrixuid"
cd "$PROJECT"
export NVM_DIR="$PROJECT/.termux-debian-nvm"
mkdir -p "$NVM_DIR"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    echo '[XRIXUID] Installing nvm in persistent project folder'
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | PROFILE=/dev/null bash
fi
. "$NVM_DIR/nvm.sh"
if ! nvm use 24 >/dev/null 2>&1; then nvm install 24; fi
nvm use 24 >/dev/null
if [ "$(node -p 'process.platform')" != 'linux' ]; then
    echo '[XRIXUID] ERROR: Node must run as Debian Linux.' >&2; exit 1
fi
if ! command -v pnpm >/dev/null 2>&1; then npm install -g pnpm@10; fi
echo "[XRIXUID] Node: $(node -v) / pnpm: $(pnpm -v)"
INNER

cat > "$ROOT/.xrixuid-single-run.sh" <<'INNER'
#!/bin/bash
set -Eeuo pipefail
PROJECT="/data/data/com.termux/files/home/projects/xrixuid"
cd "$PROJECT"
source "$PROJECT/.xrixuid-single-ensure-node.sh"
source "$PROJECT/.xrixuid.env"
if [ ! -f "$PROJECT/artifacts/api-server/dist/index.mjs" ] || [ ! -d "$PROJECT/node_modules" ]; then
    echo '[XRIXUID] Build is missing; installing dependencies and building.'
    sed -i '/linux-arm64.*": "-"/d' pnpm-workspace.yaml
    pnpm install --no-frozen-lockfile
    NODE_OPTIONS='--max-old-space-size=1536' pnpm run build:deploy
    pnpm --filter @workspace/db run push
fi
export BASE_PATH=/
echo '[XRIXUID] Starting API (8080) and frontend (3000) in one Debian process'
PORT=8080 NODE_ENV=production pnpm run start:deploy &
API_PID=$!
PORT=3000 NODE_ENV=development pnpm --filter @workspace/uid-web run dev &
WEB_PID=$!
shutdown(){
    kill "$API_PID" "$WEB_PID" 2>/dev/null || true
    wait "$API_PID" 2>/dev/null || true
    wait "$WEB_PID" 2>/dev/null || true
}
trap shutdown EXIT INT TERM
wait -n "$API_PID" "$WEB_PID" || true
echo '[XRIXUID] One of the processes exited; shutting down both.'
INNER
chmod 700 "$ROOT/.xrixuid-single-ensure-node.sh" "$ROOT/.xrixuid-single-run.sh"

if [[ "$MODE" == repair ]]; then
    msg 'Repairing Node.js path in the shared project...'
    proot-distro login --shared-home debian -- /bin/bash "$ROOT/.xrixuid-single-ensure-node.sh" || err 'Node.js recovery failed. Check output above.'
fi

# The old two-session starter is left on disk. We only stop its running sessions.
for old in xrixuid-api xrixuid-web; do
    tmux kill-session -t "$old" 2>/dev/null || true
done
if tmux has-session -t "$SESSION" 2>/dev/null; then
    msg 'Unified session is already running.'
else
    msg 'Starting one Debian session for both servers...'
    tmux new-session -d -s "$SESSION" \
      "proot-distro login --shared-home debian -- /bin/bash '$ROOT/.xrixuid-single-run.sh' >> '$LOG' 2>&1"
fi
sleep 4
if tmux has-session -t "$SESSION" 2>/dev/null; then
    msg 'Session active; server startup may still be in progress.'
    msg 'Dashboard: http://127.0.0.1:3000'
    msg "Status: bash ~/xrixuid-android-repair.sh status"
    msg "Logs:   bash ~/xrixuid-android-repair.sh logs"
else
    msg 'Process exited. Recent errors:'
    tail -n 35 "$LOG" || true
    err 'Server crashed. Android signal 9 may be responsible.'
fi
