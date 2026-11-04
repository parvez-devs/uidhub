#!/data/data/com.termux/files/usr/bin/bash
# XRIXUID fresh v3. Intentional destructive reset: only ~/projects/xrixuid and uid_operator DB.
# No backup/restore of old XRIXUID data. Other Termux projects and PostgreSQL databases are untouched.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
ROOT="$HOME/projects/xrixuid"
BASE='https://raw.githubusercontent.com/parvez-devs/uidhub/main'
STAMP="$ROOT/.xrixuid-fresh-v3-complete"
log(){ printf '\n[XRIXUID FRESH] %s\n' "$*"; }
die(){ log "ERROR: $*" >&2; exit 1; }
command -v pkg >/dev/null 2>&1 || die 'Open normal Termux, not Debian/proot.'
if [[ -f "$STAMP" ]]; then
  log 'Already rebuilt with fresh v3. Existing new data will NOT be erased.'
  bash "$HOME/xrixuid-termux.sh" status || true
  log 'Dashboard: http://127.0.0.1:3000'
  exit 0
fi

# Fail before deletion if necessary source integration files are unavailable.
for f in \
  "$HOME/xrixuid-queue-integration/setup.sh" \
  "$HOME/xrixuid-queue-integration/apply.py" \
  "$HOME/xrixuid-queue-integration/queue.ts" \
  "$HOME/xrixuid-queue-integration/queue-client.ts" \
  "$HOME/xrixuid-queue-integration/storage.ts" \
  "$HOME/xrixuid-queue-integration/queue-controls.tsx" \
  "$HOME/xrixuid-queue-413-hotfix/setup.sh" \
  "$HOME/xrixuid-queue-413-hotfix/patch.py"; do
  [[ -s "$f" ]] || die "Required on-device integration missing: $f. No reset performed."
done
log 'Installing Termux packages and downloading clean, known sources BEFORE reset.'
pkg install -y postgresql curl unzip tmux patch openssl gzip python coreutils proot-distro
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
curl -fLsS --retry 3 "$BASE/xrixuid.zip" -o "$T/xrixuid.zip"
unzip -tq "$T/xrixuid.zip" >/dev/null || die 'Clean repository archive failed integrity check; old data untouched.'
for name in xrixuid-termux.sh apply-smooth-ui-v2.sh upgrade-uid-pagination.sh trial-fetch-3x.sh trial-fetch-4x.sh xrixuid-one.sh; do
  curl -fLsS --retry 3 "$BASE/termux/$name" -o "$T/$name" || die "Cannot download $name; no reset performed."
done
for patch_file in uid-prefix.patch.gz.b64 smooth-ui-v2.patch.gz.b64; do
  curl -fLsS --retry 3 "$BASE/termux/$patch_file" -o "$T/$patch_file" || die "Cannot download $patch_file; no reset performed."
done
[[ -s "$T/xrixuid-one.sh" ]] || die 'One-command updater missing; no reset performed.'

# The user explicitly authorized deletion of the old XRIXUID installation and its DB.
log 'Stopping XRIXUID tmux sessions only.'
for name in xrixuid-api xrixuid-web xrixuid-one-update; do
  tmux kill-session -t "$name" 2>/dev/null || true
done
PGDATA="$PREFIX/var/lib/postgresql"
mkdir -p "$PGDATA"
[[ -f "$PGDATA/PG_VERSION" ]] || initdb -D "$PGDATA"
pg_ctl -D "$PGDATA" status >/dev/null 2>&1 || pg_ctl -D "$PGDATA" -l "$HOME/xrixuid-postgres.log" -o '-h 127.0.0.1' start
export PGHOST=127.0.0.1 PGPORT=5432 PGUSER="$(whoami)"
psql -X -w -v ON_ERROR_STOP=1 -d postgres -tAc 'SELECT 1' | grep -qx 1 || die 'PostgreSQL not reachable; no deletion performed.'
log 'Deleting ONLY the old uid_operator database and XRIXUID project directory. No backups.'
dropdb --if-exists --force uid_operator || die 'Could not drop XRIXUID database; stopped before deleting project files.'
createdb uid_operator || die 'Could not create fresh XRIXUID database.'
[[ "$ROOT" == "$HOME/projects/xrixuid" ]] || die 'Unexpected target path.'
rm -rf -- "$ROOT"
for path in \
  "$HOME/xrixuid-queue-backups" \
  "$HOME/xrixuid-queue-413-backups" \
  "$HOME/xrixuid-one-v2-backups" \
  "$HOME/xrixuid-pagination-backups" \
  "$HOME/xrixuid-fetch-3x-backups" \
  "$HOME/xrixuid-fetch-4x-backups" \
  "$HOME/xrixuid-ui-backups"; do rm -rf -- "$path"; done
rm -f "$HOME/.xrixuid-one-v2-applied"
mkdir -p "$HOME/projects"
unzip -oq "$T/xrixuid.zip" 'xrixuid/*' -d "$HOME/projects"
[[ -f "$ROOT/package.json" ]] || die 'Clean project did not extract.'
for name in xrixuid-termux.sh apply-smooth-ui-v2.sh upgrade-uid-pagination.sh trial-fetch-3x.sh trial-fetch-4x.sh xrixuid-one.sh; do
  cp "$T/$name" "$HOME/$name"
done

# Original launcher builds dependencies, local DB models and services.
log 'Installing clean XRIXUID and original UID separator.'
bash "$HOME/xrixuid-termux.sh" install
log 'Applying the previously selected UI, pagination and 4x mode.'
bash "$HOME/apply-smooth-ui-v2.sh"
bash "$HOME/upgrade-uid-pagination.sh" check
bash "$HOME/upgrade-uid-pagination.sh" install
bash "$HOME/trial-fetch-3x.sh" check
bash "$HOME/trial-fetch-3x.sh" install
bash "$HOME/trial-fetch-4x.sh" check
bash "$HOME/trial-fetch-4x.sh" install

log 'Adding the existing server-side queue and bounded 100-item uploads.'
bash "$HOME/xrixuid-queue-integration/setup.sh" check
bash "$HOME/xrixuid-queue-integration/setup.sh" install
bash "$HOME/xrixuid-queue-413-hotfix/setup.sh" check
bash "$HOME/xrixuid-queue-413-hotfix/setup.sh" install

# Browser state must not silently re-import previous UID data on a clean rebuild.
# Delete only XRIXUID-owned browser storage at first page load, never unrelated sites.
python - "$ROOT/artifacts/uid-web/src/main.tsx" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
anchor='    await initializeUIDStorage();'
if s.count(anchor)!=1:raise SystemExit('Browser reset hook missing; install halted.')
script='''
// XRIXUID_FRESH_V3: user explicitly requested a complete reset with no old browser UID data.
async function resetPriorXrixuidBrowserState(): Promise<void> {
  const mark = "xrixuid-fresh-v3-cleared-20261104";
  if (localStorage.getItem(mark) === "yes") return;
  for (let i = localStorage.length - 1; i >= 0; i--) {
    const key = localStorage.key(i);
    if (key && (key.startsWith("uid-operator-") || key.startsWith("xrixuid-")))
      localStorage.removeItem(key);
  }
  await new Promise<void>((resolve, reject) => {
    const request = indexedDB.deleteDatabase("xrixuid-indexeddb");
    request.onsuccess = () => resolve();
    request.onerror = () => reject(request.error);
    request.onblocked = () => reject(new Error("Close other XRIXUID browser tabs, then reload"));
  });
  localStorage.setItem(mark, "yes");
}
'''
s=s.replace(anchor,'    await resetPriorXrixuidBrowserState();\n'+anchor,1)
s=s.replace('// Hydrate IndexedDB before mounting pages that synchronously read UID records.',script+'\n// Hydrate IndexedDB before mounting pages that synchronously read UID records.',1)
p.write_text(s)
PY

log 'Applying queue conflict/Stop/Resume fix and final production build.'
bash "$HOME/xrixuid-one.sh"
[[ -f "$ROOT/artifacts/api-server/src/routes/queue.ts" ]] || die 'New queue server source missing after build.'
curl --connect-timeout 2 --max-time 8 -fsS http://127.0.0.1:8080/api/queue/current >/dev/null || die 'Queue API failed post-build health check.'
# This file prevents a subsequent rerun of the same command from erasing newly collected data.
printf 'fresh-v3\n' > "$STAMP"
# No old database or source backup is retained as requested.
for path in "$HOME/xrixuid-queue-backups" "$HOME/xrixuid-queue-413-backups" \
  "$HOME/xrixuid-one-v2-backups" "$HOME/xrixuid-pagination-backups" \
  "$HOME/xrixuid-fetch-3x-backups" "$HOME/xrixuid-fetch-4x-backups" \
  "$HOME/xrixuid-ui-backups"; do rm -rf -- "$path"; done
rm -f "$ROOT/artifacts/uid-web/src/App.tsx.before-uid-prefix" \
  "$ROOT/artifacts/uid-web/src/pages/home.tsx.before-uid-prefix" \
  "$ROOT/pnpm-workspace.yaml.before-termux-setup"
log 'READY: new XRIXUID, fresh database, 4x queue, Stop/Resume, IndexedDB.' 
log 'Dashboard: http://127.0.0.1:3000'
log 'IMPORTANT: Close old Chrome tabs, open a new one, then refresh once to clear old browser UID storage.'
