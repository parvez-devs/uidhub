#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
MODE="${1:-install}"
ROOT="$HOME/projects/xrixuid"
RAW="https://raw.githubusercontent.com/parvez-devs/uidhub/main"
die(){ echo "XRIXUID ERROR: $*" >&2; exit 1; }
say(){ echo "[XRIXUID] $*"; }
command -v pkg >/dev/null 2>&1 || die 'Run from normal Termux, not Debian (type exit).'
if [[ "$MODE" == stop ]]; then
  for x in xrixuid-api xrixuid-web; do tmux kill-session -t "$x" 2>/dev/null || true; done
  say "Servers stopped. PostgreSQL is unchanged."; exit 0
fi
if [[ "$MODE" == status ]]; then
  for x in xrixuid-api xrixuid-web; do
    if tmux has-session -t "$x" 2>/dev/null; then echo "$x: running"; else echo "$x: stopped"; fi
  done
  exit 0
fi
if [[ "$MODE" == logs ]]; then
  tail -n 50 "$HOME/xrixuid-api.log" "$HOME/xrixuid-web.log" 2>/dev/null || true
  exit 0
fi
[[ "$MODE" == install || "$MODE" == start ]] || die 'Use install, start, stop, status, or logs.'
pkg install -y proot-distro postgresql curl unzip tmux patch openssl gzip
if [[ ! -f "$ROOT/package.json" ]]; then
  mkdir -p "$HOME/projects"
  ZIP=''
  for f in /sdcard/ck/xrixuid_uid_separator.zip /sdcard/Download/Telegram/xrixuid_uid_separator.zip /sdcard/ck/xrixuid.zip /sdcard/Download/Telegram/xrixuid.zip; do
    if [[ -f "$f" ]]; then ZIP="$f"; break; fi
  done
  if [[ -z "$ZIP" ]]; then
    ZIP="$HOME/projects/xrixuid-github.zip"
    say 'Downloading project archive from GitHub'
    curl -fL --retry 3 "$RAW/xrixuid.zip" -o "$ZIP"
  fi
  unzip -tq "$ZIP" >/dev/null || die 'Invalid project ZIP'
  unzip -nq "$ZIP" 'xrixuid/*' -d "$HOME/projects"
fi
[[ -f "$ROOT/package.json" ]] || die 'Project missing: xrixuid/package.json'
if ! grep -Fq uidPrefix "$ROOT/artifacts/uid-web/src/pages/home.tsx"; then
  say 'Applying UID prefix separator patch'
  cp -p "$ROOT/artifacts/uid-web/src/App.tsx" "$ROOT/artifacts/uid-web/src/App.tsx.before-uid-prefix"
  cp -p "$ROOT/artifacts/uid-web/src/pages/home.tsx" "$ROOT/artifacts/uid-web/src/pages/home.tsx.before-uid-prefix"
  curl -fL --retry 3 "$RAW/termux/uid-prefix.patch.gz.b64" -o "$HOME/projects/uid-prefix.patch.gz.b64"
  base64 -d "$HOME/projects/uid-prefix.patch.gz.b64" | gzip -dc > "$HOME/projects/uid-prefix.patch"
  (cd "$ROOT" && patch --batch --forward --fuzz=0 -p1 < "$HOME/projects/uid-prefix.patch") || die 'Patch incompatible with this project. Original files saved.'
fi
PGDATA="$PREFIX/var/lib/postgresql"
mkdir -p "$PGDATA"
[[ -f "$PGDATA/PG_VERSION" ]] || initdb -D "$PGDATA"
pg_ctl -D "$PGDATA" status >/dev/null 2>&1 || pg_ctl -D "$PGDATA" -l "$HOME/xrixuid-postgres.log" -o '-h 127.0.0.1' start
export PGHOST=127.0.0.1 PGPORT=5432 PGUSER="$(whoami)"
[[ "$(psql -d postgres -tAc "select 1 from pg_database where datname='uid_operator'" | tr -d '[:space:]')" == 1 ]] || createdb uid_operator
printf '%s\n' "$PGUSER" > "$ROOT/.termux-db-user"
psql -d uid_operator -tAc 'select 1' >/dev/null || die 'Database connection failed'
if [[ ! -s "$ROOT/.xrixuid.env" ]]; then
  umask 077
  printf "export DATABASE_URL='postgresql://%s@127.0.0.1:5432/uid_operator'\nexport ADMIN_KEY='%s'\nexport BASE_PATH='/'\n" "$PGUSER" "$(openssl rand -hex 24)" > "$ROOT/.xrixuid.env"
  chmod 600 "$ROOT/.xrixuid.env"
fi
if ! proot-distro login --shared-home debian -- /bin/true >/dev/null 2>&1; then
  say 'Installing Debian'
  proot-distro install debian
fi
cat > "$ROOT/.launch-api.sh" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
cd "$HOME/projects/xrixuid"
export NVM_DIR="$HOME/.nvm"
. "$NVM_DIR/nvm.sh"
nvm use 24 >/dev/null
. ./.xrixuid.env
export PORT=8080 NODE_ENV=production
exec pnpm run start:deploy
EOF
cat > "$ROOT/.launch-web.sh" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
cd "$HOME/projects/xrixuid"
export NVM_DIR="$HOME/.nvm"
. "$NVM_DIR/nvm.sh"
nvm use 24 >/dev/null
. ./.xrixuid.env
export PORT=3000 BASE_PATH=/ NODE_ENV=development
exec pnpm --filter @workspace/uid-web run dev
EOF
if [[ "$MODE" == install ]]; then
  cat > "$ROOT/.build-termux.sh" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates build-essential python3 openssl git
export NVM_DIR="$HOME/.nvm"
if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi
. "$NVM_DIR/nvm.sh"
nvm install 24
nvm use 24
[[ "$(node -p 'process.platform + " " + process.arch')" == 'linux arm64' ]] || { echo 'Wrong Node binary: must be Debian linux arm64'; exit 1; }
npm install -g pnpm@10
cd "$HOME/projects/xrixuid"
cp -n pnpm-workspace.yaml pnpm-workspace.yaml.before-termux-setup || true
sed -i -e '/"esbuild>@esbuild\/linux-arm64": "-"/d' \
  -e '/"lightningcss>lightningcss-linux-arm64-gnu": "-"/d' \
  -e '/"@tailwindcss\/oxide>@tailwindcss\/oxide-linux-arm64-gnu": "-"/d' \
  -e '/"rollup>@rollup\/rollup-linux-arm64-gnu": "-"/d' pnpm-workspace.yaml
pnpm install --no-frozen-lockfile
. ./.xrixuid.env
pnpm --filter @workspace/db run push
pnpm run build:deploy
EOF
  say 'Building project (first setup only)'
  proot-distro login --shared-home debian -- /bin/bash "$ROOT/.build-termux.sh" || die 'Build failed. Check output above.'
fi
[[ -f "$ROOT/artifacts/api-server/dist/index.mjs" ]] || die 'Missing API build. Run install first.'
for spec in 'xrixuid-api:.launch-api.sh:xrixuid-api.log' 'xrixuid-web:.launch-web.sh:xrixuid-web.log'; do
  IFS=: read -r session script log <<< "$spec"
  if ! tmux has-session -t "$session" 2>/dev/null; then
    tmux new-session -d -s "$session" "proot-distro login --shared-home debian -- /bin/bash '$ROOT/$script' 2>&1 | tee -a '$HOME/$log'"
  fi
done
say 'Dashboard: http://127.0.0.1:3000'
say 'API: http://127.0.0.1:8080'
say 'Commands: bash ~/xrixuid-termux.sh status | logs | stop | start'
