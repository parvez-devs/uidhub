#!/data/data/com.termux/files/usr/bin/bash
# XRIXUID Fetch 3x Trial — opt-in and fully reversible.
# Only modifies $HOME/projects/xrixuid/artifacts/uid-web/src/hooks/use-uids.ts.
set -Eeuo pipefail
MODE="${1:-check}"
ROOT="$HOME/projects/xrixuid"
SOURCE="$ROOT/artifacts/uid-web/src/hooks/use-uids.ts"
BACKUPS="$HOME/xrixuid-fetch-3x-backups"

say() { printf 'XRIXUID FETCH 3X: %s\n' "$*"; }
fail() { printf 'XRIXUID FETCH 3X: ERROR: %s\n' "$*" >&2; exit 1; }
command -v pkg >/dev/null 2>&1 || fail 'Run this in normal Termux, not Debian.'
case "$MODE" in check|install|rollback|status) ;; *) fail 'Usage: check | install | rollback | status' ;; esac
[[ -f "$SOURCE" ]] || fail "Existing frontend not found: $SOURCE"
# Python is used only to verify/change exactly one file atomically.
if ! command -v python >/dev/null 2>&1; then
  if [[ "$MODE" == install || "$MODE" == check ]]; then
    pkg install -y python >/dev/null
  else
    fail 'Python missing. Install it once with: pkg install python'
  fi
fi

python - "$MODE" "$SOURCE" "$BACKUPS" <<'PY'
from __future__ import annotations
from datetime import datetime
from pathlib import Path
import hashlib
import os
import re
import shutil
import sys
import tempfile

mode, filename, dirname = sys.argv[1:]
target = Path(filename)
backups = Path(dirname)
marker = 'XRIXUID_FETCH_3X_V1'
original = target.read_text(encoding='utf-8')


def digest(text: str) -> str:
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def stop(message: str) -> None:
    raise SystemExit('XRIXUID FETCH 3X: ERROR: ' + message)


def install_patch(source: str) -> str:
    if marker in source:
        return source
    # Preserve all requests, error handling, result updates, and existing CHUNK_SIZE.
    head = '    for (let i = 0; i < toFetch.length; i += CHUNK_SIZE) {\n      const chunk = toFetch.slice(i, i + CHUNK_SIZE);\n'
    tail = '    }\n  }, []);'
    if source.count(head) != 1 or source.count(tail) != 1:
        stop('Unexpected fetch hook structure. No files changed.')
    h = source.index(head)
    t = source.index(tail, h + len(head))
    content = source[h + len(head):t]
    if 'try {' not in content or 'updateUIDs(updates)' not in content or 'Chunk fetch failed' not in content:
        stop('Fetch/update handlers differ from expected. No files changed.')
    if 'const CHUNK_SIZE = 30;' not in source:
        stop('Original 30-UID batch size differs. No files changed.')

    shifted = ''.join('  ' + line if line.strip() else line for line in content.splitlines(keepends=True))
    parallel = (
        '    // ' + marker + ': three standard 30-UID chunks in flight at most.\n'
        '    let nextChunkStart = 0;\n'
        '    const fetchWorker = async () => {\n'
        '      while (nextChunkStart < toFetch.length) {\n'
        '        const i = nextChunkStart;\n'
        '        nextChunkStart += CHUNK_SIZE;\n'
        '        const chunk = toFetch.slice(i, i + CHUNK_SIZE);\n'
        + shifted +
        '      }\n'
        '    };\n'
        '    const workerCount = Math.min(3, Math.ceil(toFetch.length / CHUNK_SIZE));\n'
        '    await Promise.all(Array.from({ length: workerCount }, () => fetchWorker()));\n'
    )
    patched = source[:h] + parallel + source[t + len('    }\n'):]
    if patched.count(marker) != 1 or patched.count('updateUIDs(updates)') != source.count('updateUIDs(updates)'):
        stop('Patch validation failed. No files changed.')
    return patched


def write_atomic(text: str) -> None:
    fd, name = tempfile.mkstemp(prefix='.use-uids-fetch-', suffix='.ts', dir=target.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='') as fp:
            fp.write(text)
        os.chmod(name, target.stat().st_mode & 0o777)
        os.replace(name, target)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def backup_info():
    latest = backups / 'latest'
    if not latest.is_file():
        stop('No prior trial backup found; original file unchanged.')
    backup_name = latest.read_text(encoding='utf-8').strip()
    if not re.fullmatch(r'use-uids-\d{8}-\d{6}-\d+\.ts', backup_name):
        stop('Invalid backup reference. No files changed.')
    backup = backups / backup_name
    if not backup.is_file():
        stop('Original source backup missing. No files changed.')
    return backup

if mode == 'status':
    print('XRIXUID FETCH 3X: ' + ('TRIAL ON (three chunks)' if marker in original else 'ORIGINAL MODE (single chunk)'))
    raise SystemExit(0)

if mode == 'rollback':
    backup = backup_info()
    if marker not in original:
        print('XRIXUID FETCH 3X: Already in original mode; no changes made.')
        raise SystemExit(0)
    patched_hash = backups / 'installed.sha256'
    if not patched_hash.is_file() or patched_hash.read_text(encoding='ascii').strip() != digest(original):
        stop('Fetch hook changed after installation. Refusing to overwrite edits; manual comparison required.')
    saved = backup.read_text(encoding='utf-8')
    if marker in saved:
        stop('Original backup unexpectedly contains trial code. No files changed.')
    write_atomic(saved)
    print('XRIXUID FETCH 3X: ROLLBACK COMPLETE. Original one-chunk-at-a-time fetch restored.')
    print('XRIXUID FETCH 3X: Other files, database, UID records, pagination and UI preserved.')
    print('Refresh dashboard; do not roll back during an active fetch.')
    raise SystemExit(0)

if marker in original:
    print('XRIXUID FETCH 3X: Trial is already installed. No changes needed.')
    raise SystemExit(0)
patched = install_patch(original)
if mode == 'check':
    print('XRIXUID FETCH 3X: Compatible hook. Trial only changes fetch chunk concurrency from 1 to 3.')
    raise SystemExit(0)

backups.mkdir(parents=True, exist_ok=True, mode=0o700)
backup = backups / ('use-uids-' + datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + str(os.getpid()) + '.ts')
with backup.open('x', encoding='utf-8') as stream:
    stream.write(original)
backup.chmod(0o600)
# Store the backup pointer and installed content hash before replacing the source.
(backups / 'latest').write_text(backup.name + '\n', encoding='utf-8')
(backups / 'installed.sha256').write_text(digest(patched) + '\n', encoding='ascii')
write_atomic(patched)
print('XRIXUID FETCH 3X: Trial installed: three parallel 30-UID chunks, versus one previously.')
print(f'XRIXUID FETCH 3X: Exact original source backed up at {backup}')
print('XRIXUID FETCH 3X: Only artifacts/uid-web/src/hooks/use-uids.ts modified.')
print('XRIXUID FETCH 3X: Refresh the dashboard before testing; throughput depends on network and API limits.')
print('XRIXUID FETCH 3X: To restore previous behavior: bash ~/trial-fetch-3x.sh rollback')
PY
