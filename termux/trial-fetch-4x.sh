#!/data/data/com.termux/files/usr/bin/bash
# XRIXUID 4x fetch trial. Apply only to an already-installed 3x trial.
# Changes only artifacts/uid-web/src/hooks/use-uids.ts. Rollback restores exactly the 3x version.
set -Eeuo pipefail
MODE="${1:-check}"
SOURCE="$HOME/projects/xrixuid/artifacts/uid-web/src/hooks/use-uids.ts"
BACKUPS="$HOME/xrixuid-fetch-4x-backups"

fail() { printf 'XRIXUID FETCH 4X: ERROR: %s\n' "$*" >&2; exit 1; }
command -v pkg >/dev/null 2>&1 || fail 'Run in normal Termux (not Debian).'
case "$MODE" in check|install|rollback|status) ;; *) fail 'Usage: check | install | status | rollback' ;; esac
[[ -f "$SOURCE" ]] || fail "Fetch hook missing: $SOURCE"
command -v python >/dev/null 2>&1 || fail 'Python not found. Run: pkg install python -y'

python - "$MODE" "$SOURCE" "$BACKUPS" <<'PY'
from datetime import datetime
from pathlib import Path
import hashlib
import os
import re
import sys
import tempfile

mode, filename, dirname = sys.argv[1:]
target = Path(filename)
backups = Path(dirname)
source = target.read_bytes()

# Explicitly require the previous, working 3x patch and its unchanged batch size.
marker = b'XRIXUID_FETCH_3X_V1'
old = b'const workerCount = Math.min(3, Math.ceil(toFetch.length / CHUNK_SIZE));'
new = b'const workerCount = Math.min(4, Math.ceil(toFetch.length / CHUNK_SIZE));'
chunk_size = b'const CHUNK_SIZE = 30;'


def die(message):
    raise SystemExit('XRIXUID FETCH 4X: ERROR: ' + message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def atomic_replace(data):
    fd, name = tempfile.mkstemp(prefix='.use-uids-4x-', suffix='.ts', dir=target.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.chmod(name, target.stat().st_mode & 0o777)
        os.replace(name, target)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def current_mode():
    if source.count(marker) == 1 and source.count(chunk_size) == 1:
        if source.count(new) == 1 and old not in source:
            return '4x'
        if source.count(old) == 1 and new not in source:
            return '3x'
    return 'unknown'


state = current_mode()
if mode == 'status':
    print('XRIXUID FETCH 4X: ' + (state + ' parallel fetching' if state != 'unknown' else 'Unrecognized source; no changes made'))
    raise SystemExit(0)

if mode in ('check', 'install'):
    if state == '4x':
        print('XRIXUID FETCH 4X: Trial already installed; no change.')
        raise SystemExit(0)
    if state != '3x':
        die('Expected prior 3x trial not found. No changes made.')
    patched = source.replace(old, new, 1)
    assert patched.replace(new, old, 1) == source
    if mode == 'check':
        print('XRIXUID FETCH 4X: Compatible 3x trial detected; ready for limited 4x test.')
        raise SystemExit(0)
    backups.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(backups, 0o700)
    backup_name = 'use-uids-3x-' + datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + str(os.getpid()) + '.ts'
    backup = backups / backup_name
    with backup.open('xb') as f:
        f.write(source)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(backup, 0o600)
    (backups / 'latest').write_text(backup_name + '\n', encoding='utf-8')
    (backups / 'installed.sha256').write_text(sha(patched) + '\n', encoding='ascii')
    atomic_replace(patched)
    print('XRIXUID FETCH 4X: Installed. Now up to 4 parallel chunks of 30 UIDs (was 3).')
    print('XRIXUID FETCH 4X: Previous 3x source backed up: ' + str(backup))
    print('XRIXUID FETCH 4X: Only use-uids.ts changed; no UI, backend, database or UID records modified.')
    print('XRIXUID FETCH 4X: Refresh the browser before testing.')
    print('XRIXUID FETCH 4X: To return directly to 3x: bash ~/trial-fetch-4x.sh rollback')
    raise SystemExit(0)

# Roll back only this 4x trial; leave the earlier 3x trial installed.
if mode == 'rollback':
    if state == '3x':
        print('XRIXUID FETCH 4X: Already running the previous 3x mode. No change.')
        raise SystemExit(0)
    if state != '4x':
        die('Unknown fetch source; cannot safely roll back.')
    latest = backups / 'latest'
    recorded_hash = backups / 'installed.sha256'
    if not latest.is_file() or not recorded_hash.is_file():
        die('4x backup manifest missing. No files changed.')
    backup_name = latest.read_text(encoding='utf-8').strip()
    if not re.fullmatch(r'use-uids-3x-\d{8}-\d{6}-\d+\.ts', backup_name):
        die('Backup reference invalid. No files changed.')
    backup = backups / backup_name
    if not backup.is_file():
        die('Previous 3x backup missing. No files changed.')
    if sha(source) != recorded_hash.read_text(encoding='ascii').strip():
        die('Fetch source edited since installation. Refusing to overwrite later edits.')
    old_source = backup.read_bytes()
    if old_source.count(old) != 1 or new in old_source or old_source.count(marker) != 1:
        die('Backup is not the expected 3x source. No files changed.')
    if old_source.replace(old, new, 1) != source:
        die('Trial change mismatch. No files changed.')
    atomic_replace(old_source)
    print('XRIXUID FETCH 4X: ROLLBACK COMPLETE — exact previous 3x fetch restored.')
    print('XRIXUID FETCH 4X: UID data, pagination, database, UI and original 3x backup untouched.')
    print('XRIXUID FETCH 4X: Refresh browser; do not roll back during an active fetch.')
PY
