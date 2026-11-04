#!/data/data/com.termux/files/usr/bin/bash
# XRIXUID ONE v2 — preserve existing project, 4x worker, local data and database.
# Usage: bash ~/xrixuid-one.sh [install|status|start|rollback|logs]
set -Eeuo pipefail
MODE="${1:-install}"
ROOT="$HOME/projects/xrixuid"
LAUNCH="$HOME/xrixuid-termux.sh"
SELF="$HOME/xrixuid-one.sh"
STATE="$HOME/.xrixuid-one-v2-applied"
BACKUP="$HOME/xrixuid-one-v2-backups"
BRANCH_413="https://raw.githubusercontent.com/parvez-devs/uidhub/hotfix/queue-413-v1-2-download/termux"
log() { printf '[XRIXUID ONE] %s\n' "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
[[ -f "$ROOT/package.json" && -f "$LAUNCH" ]] || fail 'Existing XRIXUID or Termux launcher missing. Nothing changed.'
command -v pkg >/dev/null 2>&1 || fail 'Run from normal Termux, not Debian.'
case "$MODE" in install|wait|status|start|logs|rollback) ;; *) fail 'Usage: install | status | start | logs | rollback' ;; esac
[[ "$MODE" == logs ]] && { bash "$LAUNCH" logs; exit 0; }
[[ "$MODE" == start ]] && { termux-wake-lock 2>/dev/null || true; bash "$LAUNCH" start; exit 0; }

# Return 0 when idle; "unknown" if PostgreSQL cannot be read. Never guess.
active() {
  local dbuser count
  if ! grep -Fq 'XRIXUID_QUEUE_V1' "$ROOT/artifacts/api-server/src/app.ts" 2>/dev/null; then
    printf '0'; return
  fi
  dbuser="$(cat "$ROOT/.termux-db-user" 2>/dev/null || whoami)"
  count="$(PGHOST=127.0.0.1 PGPORT=5432 PGUSER="$dbuser" psql -d uid_operator -tAc "
    SELECT (SELECT count(*) FROM xrixuid_jobs WHERE state='running') +
           (SELECT count(*) FROM xrixuid_items WHERE state='inflight')
  " 2>/dev/null | tr -d '[:space:]')" || { printf 'unknown'; return; }
  [[ "$count" =~ ^[0-9]+$ ]] && printf '%s' "$count" || printf 'unknown'
}
report() {
  bash "$LAUNCH" status || true
  local dbuser
  dbuser="$(cat "$ROOT/.termux-db-user" 2>/dev/null || whoami)"
  if grep -Fq XRIXUID_QUEUE_V1 "$ROOT/artifacts/api-server/src/app.ts" 2>/dev/null; then
    PGHOST=127.0.0.1 PGPORT=5432 PGUSER="$dbuser" psql -d uid_operator -P pager=off -c "
      SELECT state,count(*) AS jobs,sum((SELECT count(*) FROM xrixuid_items i WHERE i.job_id=j.id)) AS items
      FROM xrixuid_jobs j GROUP BY state ORDER BY state
    " 2>/dev/null || true
    curl --connect-timeout 2 --max-time 6 -fsS http://127.0.0.1:8080/api/queue/current 2>/dev/null || true
    echo
  fi
  log 'Dashboard: http://127.0.0.1:3000'
}
if [[ "$MODE" == status ]]; then report; exit 0; fi

# V2 patch: fix duplicate-start 409 overlay and prefer active job on status.
# Restore only if exact installed SHA still matches (never overwrite later edits).
reliability() {
python - "$1" "$ROOT" "$BACKUP" <<'PY'
from pathlib import Path
from datetime import datetime
import hashlib, json, os, sys, tempfile
mode,root_s,back_s=sys.argv[1:]
root=Path(root_s); back=Path(back_s)
paths=['artifacts/api-server/src/routes/queue.ts',
       'artifacts/uid-web/src/lib/queue-client.ts',
       'artifacts/uid-web/vite.config.ts']
marker='XRIXUID_ONE_RELIABILITY_V2'
def sha(x):return hashlib.sha256(x).hexdigest()
def fail(s):raise SystemExit('[XRIXUID ONE] '+s)
def one(s,old,new):
    if s.count(old)!=1:fail('Incompatible source near '+repr(old[:75])+'; untouched')
    return s.replace(old,new,1)
def atomic(path,data):
    fd,tmp=tempfile.mkstemp(prefix='.xrixuid-one-',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as f:f.write(data);f.flush();os.fsync(f.fileno())
        os.chmod(tmp,path.stat().st_mode & 0o777)
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)
def restore():
    latest=back/'latest'
    if not latest.is_file():fail('No V2 source backup; cannot rollback V2')
    stamp=latest.read_text().strip()
    if '/' in stamp or stamp in ('','.','..'):fail('Invalid V2 backup pointer')
    folder=back/stamp; meta=json.loads((folder/'manifest.json').read_text())
    if meta['root']!=str(root):fail('Backup belongs to a different XRIXUID')
    for p in paths:
        if sha((root/p).read_bytes()) != meta['installed'][p]:fail('Source modified since patch: '+p)
        if sha((folder/p).read_bytes()) != meta['original'][p]:fail('Backup corrupted: '+p)
    for p in paths:atomic(root/p,(folder/p).read_bytes())
    latest.unlink()
    print('[XRIXUID ONE] V2 original source restored; queue data retained')
if mode=='rollback':restore();sys.exit(0)
for p in paths:
    if not (root/p).is_file():fail('Queue integration missing file: '+p)
src={p:(root/p).read_bytes() for p in paths}
s={p:src[p].decode('utf-8') for p in paths}
installed=[marker in s[p] for p in paths]
if all(installed):
    print('[XRIXUID ONE] V2 patch already installed');sys.exit(0)
if any(installed):fail('V2 source is partially patched; inspect before retry')
server=s[paths[0]]
server=one(server,'SELECT id FROM xrixuid_jobs ORDER BY created_at DESC LIMIT 1',
   "SELECT id FROM xrixuid_jobs ORDER BY CASE state WHEN 'running' THEN 0 WHEN 'paused' THEN 1 ELSE 2 END, created_at DESC LIMIT 1")
server=one(server,"export const queueRouter = Router();","export const queueRouter = Router(); // "+marker)
client=s[paths[1]]
signature='export async function startBackgroundFetch(items:UIDEntry[]):Promise<void> {'
client=one(client,signature,'async function performStartBackgroundFetch(items:UIDEntry[]):Promise<void> {')
anchor='\nexport async function stopBackgroundFetch():Promise<void> {'
wrapper="""
// XRIXUID_ONE_RELIABILITY_V2: serialize starts and render queue conflicts as status.
let queuedStart:Promise<void>|null=null;
export function startBackgroundFetch(items:UIDEntry[]):Promise<void> {
  if(queuedStart)return queuedStart;
  queuedStart=(async()=>{
    if(!items.length)return;
    try {
      const {job}=await request<{job:JobStatus|null}>('/current');
      if(job&&(job.state==='running'||job.state==='paused')){
        currentJob=job;
        localStorage.setItem(ACTIVE_KEY,job.id);
        lastError=job.state==='running'
          ? 'Another job is running. Imported UIDs are retained; fetch pending UIDs when it completes.'
          : 'A paused job exists. Resume or finish it before starting another.';
        emit();
        return;
      }
      await performStartBackgroundFetch(items);
    } catch(err) {
      try {
        const {job}=await request<{job:JobStatus|null}>('/current');
        if(job){currentJob=job;localStorage.setItem(ACTIVE_KEY,job.id);}
      } catch (_) { /* keep original message */ }
      lastError='Fetch not started: '+(err instanceof Error?err.message:String(err));
      emit(); // no unhandled rejection or Vite red overlay
    }
  })().finally(()=>{queuedStart=null;});
  return queuedStart;
}
"""
client=one(client,anchor,wrapper+anchor)
client=one(client,"    lastError=null;emit();\n  } catch(e) {\n    lastError=e instanceof Error?e.message:String(e);\n    emit();\n  } finally {inPoll=false;}",
    "    if(!lastError?.startsWith('Fetch not started:')&&!lastError?.startsWith('Another job is running.'))lastError=null;emit();\n  } catch(e) {\n    lastError=e instanceof Error?e.message:String(e);\n    emit();\n  } finally {inPoll=false;}")
vite=s[paths[2]]
old="hmr: (process.env.HOME || '').includes('/data/data/com.termux') ? false : undefined,"
new="hmr: (process.env.PORT === '3000' || (process.env.HOME || '').includes('/data/data/com.termux')) ? false : undefined, // "+marker
vite=one(vite,old,new)
changed={paths[0]:server.encode(),paths[1]:client.encode(),paths[2]:vite.encode()}
if mode=='check':
    print('[XRIXUID ONE] V2 compatibility check passed; no files changed');sys.exit(0)
if mode!='install':fail('Unknown V2 action')
if (back/'latest').exists():fail('Previous V2 backup exists; check before proceeding')
back.mkdir(mode=0o700,parents=True,exist_ok=True)
stamp=datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+str(os.getpid())
folder=back/stamp;folder.mkdir()
meta={'root':str(root),'original':{},'installed':{}}
for p in paths:
    dst=folder/p;dst.parent.mkdir(parents=True,exist_ok=True)
    dst.write_bytes(src[p]);os.chmod(dst,0o600)
    meta['original'][p]=sha(src[p]);meta['installed'][p]=sha(changed[p])
(folder/'manifest.json').write_text(json.dumps(meta,indent=2))
(back/'latest').write_text(stamp+'\n')
for p in paths:atomic(root/p,changed[p])
print('[XRIXUID ONE] Queue conflicts, duplicate starts, and Termux Vite HMR patched')
PY
}
build() {
  proot-distro login --shared-home debian -- /bin/bash -lc '
    set -Eeuo pipefail
    export NVM_DIR="$HOME/.nvm"
    . "$NVM_DIR/nvm.sh"
    nvm use 24 >/dev/null
    cd "$HOME/projects/xrixuid"
    pnpm --filter @workspace/api-server run typecheck
    pnpm --filter @workspace/uid-web run typecheck
    pnpm run build:deploy
  '
}
health() {
  local n code
  for n in $(seq 1 25); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 3 \
      http://127.0.0.1:8080/api/queue/current || true)"
    if [[ "$code" == 200 ]]; then return 0; fi
    sleep 2
  done
  return 1
}
rollback_applied() {
  local had=0
  if [[ -f "$STATE" ]]; then
    if grep -qx v2 "$STATE"; then
      reliability rollback && had=1 || return 1
      sed -i '/^v2$/d' "$STATE"
    fi
    if grep -qx v12 "$STATE"; then
      bash "$HOME/xrixuid-queue-413-hotfix/setup.sh" rollback && had=1 || return 1
      sed -i '/^v12$/d' "$STATE"
    fi
    if grep -qx v11 "$STATE"; then
      bash "$HOME/xrixuid-queue-integration/setup.sh" rollback && had=1 || return 1
      sed -i '/^v11$/d' "$STATE"
    fi
  fi
  if [[ "$had" == 1 ]]; then
    build
    bash "$LAUNCH" stop
    bash "$LAUNCH" start
  fi
  return 0
}
if [[ "$MODE" == rollback ]]; then
  [[ "$(active)" == 0 ]] || fail 'Queue active or unreadable; finish or pause job before rollback.'
  rollback_applied
  log 'Rollback done for changes applied by XRIXUID ONE only. Other project files and data retained.'
  exit 0
fi
if [[ "$MODE" == wait ]]; then
  log 'Waiting locally for existing queue to become idle; will not interrupt running jobs.'
  while true; do
    count="$(active)"
    if [[ "$count" == 0 ]]; then break; fi
    sleep 20
  done
  MODE=install
fi

count="$(active)"
if [[ "$count" != 0 ]]; then
  if [[ "$count" == unknown ]]; then
    fail 'Cannot read existing PostgreSQL queue state; refusing to restart or overwrite.'
  fi
  command -v tmux >/dev/null 2>&1 || fail 'tmux not installed; cannot defer safely.'
  if tmux has-session -t xrixuid-one-update 2>/dev/null; then
    log 'An updater is already waiting for the active job to finish.'
  else
    tmux new-session -d -s xrixuid-one-update "bash '$SELF' wait >>'$HOME/xrixuid-one-v2.log' 2>&1"
    log "Job active ($count running/in-flight markers). Update queued locally without interrupting it."
    log "After it completes, check: tail -n 30 ~/xrixuid-one-v2.log"
  fi
  log 'Dashboard continues at http://127.0.0.1:3000'
  exit 0
fi

# The existing v1.1 queue and 4x worker are preserved. Install missing layers only.
NEW_V11=0
NEW_V12=0
NEW_V2=0
rollback_current_run() {
  if [[ "$NEW_V2" == 1 ]]; then
    reliability rollback || true
    sed -i '/^v2$/d' "$STATE" 2>/dev/null || true
  fi
  if [[ "$NEW_V12" == 1 ]]; then
    bash "$HOME/xrixuid-queue-413-hotfix/setup.sh" rollback || true
    sed -i '/^v12$/d' "$STATE" 2>/dev/null || true
  fi
  if [[ "$NEW_V11" == 1 ]]; then
    bash "$HOME/xrixuid-queue-integration/setup.sh" rollback || true
    sed -i '/^v11$/d' "$STATE" 2>/dev/null || true
  fi
  if [[ "$NEW_V2" == 1 || "$NEW_V12" == 1 || "$NEW_V11" == 1 ]]; then
    build || true
    bash "$LAUNCH" stop || true
    bash "$LAUNCH" start || true
  fi
}
on_exit() {
  local rc=$?
  trap - EXIT
  if [[ "$rc" != 0 ]]; then
    log "Update failed (exit $rc). Restoring only changes made by this run."
    rollback_current_run
  fi
  exit "$rc"
}
trap on_exit EXIT
termux-wake-lock 2>/dev/null || true
if ! grep -Fq XRIXUID_QUEUE_V1 "$ROOT/artifacts/api-server/src/app.ts"; then
  [[ -f "$HOME/xrixuid-queue-integration/setup.sh" ]] ||
    fail 'v1.1 integration not on device. No changes made; existing project remains intact.'
  log 'Installing queue into the existing project (keeping all UID data).'
  bash "$HOME/xrixuid-queue-integration/setup.sh" check
  bash "$HOME/xrixuid-queue-integration/setup.sh" install
  echo v11 >> "$STATE"
  NEW_V11=1
fi
QUEUE_SERVER="$ROOT/artifacts/api-server/src/routes/queue.ts"
QUEUE_CLIENT="$ROOT/artifacts/uid-web/src/lib/queue-client.ts"
[[ -f "$QUEUE_SERVER" && -f "$QUEUE_CLIENT" ]] || fail 'Expected integrated queue files missing.'
has_server=0;has_client=0
grep -Fq XRIXUID_QUEUE_UPLOAD_V12 "$QUEUE_SERVER" && has_server=1 || true
grep -Fq XRIXUID_QUEUE_UPLOAD_V12 "$QUEUE_CLIENT" && has_client=1 || true
[[ "$has_server" == "$has_client" ]] || fail 'Partial v1.2 hotfix detected; no changes made.'
if [[ "$has_server" == 0 ]]; then
  if [[ ! -f "$HOME/xrixuid-queue-413-hotfix/setup.sh" ]]; then
    log 'Retrieving verified 413 fix from GitHub.'
    mkdir -p "$HOME/xrixuid-one-downloads"
    curl -fLsS --retry 3 "$BRANCH_413/XRIXUID-existing-queue-413-hotfix-v1.2.zip.b64" -o "$HOME/xrixuid-one-downloads/hotfix.b64"
    base64 -d "$HOME/xrixuid-one-downloads/hotfix.b64" > "$HOME/xrixuid-one-downloads/hotfix.zip"
    echo "c368c37b793047536decc2e35b209d47e2607f9ebc3bfda5611fafa79894991b  $HOME/xrixuid-one-downloads/hotfix.zip" | sha256sum -c -
    unzip -oq "$HOME/xrixuid-one-downloads/hotfix.zip" -d "$HOME"
  fi
  log 'Applying bounded 100-UID upload fix (HTTP 413).'
  bash "$HOME/xrixuid-queue-413-hotfix/setup.sh" check
  bash "$HOME/xrixuid-queue-413-hotfix/setup.sh" install
  echo v12 >> "$STATE"
  NEW_V12=1
fi
if ! grep -Fq XRIXUID_ONE_RELIABILITY_V2 "$QUEUE_SERVER"; then
  reliability check
  reliability install
  echo v2 >> "$STATE"
  NEW_V2=1
  log 'Building and validating the existing project.'
  build
  bash "$LAUNCH" stop
  bash "$LAUNCH" start
fi
health || fail 'Queue health check failed'
trap - EXIT
log 'READY: http://127.0.0.1:3000'
log 'Home: Stop/Resume, 4x server worker, real progress, 300-card pagination, IndexedDB.'
log 'If needed: bash ~/xrixuid-one.sh status | rollback | logs'
report
