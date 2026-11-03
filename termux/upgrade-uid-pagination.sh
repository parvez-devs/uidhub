#!/data/data/com.termux/files/usr/bin/bash
# XRIXUID UI pagination upgrade: changes only artifacts/uid-web/src/pages/home.tsx.
# Requires the existing UID prefix and Smooth UI v2 patches shown in the dashboard.
set -Eeuo pipefail
MODE="${1:-install}"
ROOT="$HOME/projects/xrixuid"
SOURCE="$ROOT/artifacts/uid-web/src/pages/home.tsx"
BACKUPS="$HOME/xrixuid-pagination-backups"

fail() { printf 'XRIXUID PAGINATION: ERROR: %s\n' "$*" >&2; exit 1; }
command -v pkg >/dev/null 2>&1 || fail 'Run this from normal Termux (not Debian/proot).'

if [[ "$MODE" == rollback ]]; then
  [[ -s "$BACKUPS/latest" ]] || fail 'No backup available.'
  BACKUP="$(cat "$BACKUPS/latest")"
  case "$BACKUP" in "$BACKUPS"/*) ;; *) fail 'Unsafe backup path.' ;; esac
  [[ -f "$BACKUP" ]] || fail "Backup missing: $BACKUP"
  cp -p "$BACKUP" "$SOURCE"
  echo 'XRIXUID PAGINATION: Previous home.tsx restored. Refresh browser.'
  exit 0
fi
[[ "$MODE" == install || "$MODE" == check ]] || fail 'Usage: install | check | rollback'
[[ -f "$SOURCE" ]] || fail "Missing frontend: $SOURCE"
pkg install -y python >/dev/null

python - "$SOURCE" "$BACKUPS" "$MODE" <<'PY'
import pathlib
import re
import sys
import tempfile
from datetime import datetime

file_path = pathlib.Path(sys.argv[1])
backup_dir = pathlib.Path(sys.argv[2])
mode = sys.argv[3]
src = file_path.read_text(encoding="utf-8")
marker = "XRX_UID_PAGER_V1"
if marker in src:
    print("XRIXUID PAGINATION: Already installed. No changes required.")
    sys.exit(0)

# Fail closed on unexpected frontend versions. All data, backend, and card files stay untouched.
required = (
    'const [statusFilter, setStatusFilter]',
    'const [visibleCount, setVisibleCount]',
    'const sentinelRef = useRef<HTMLDivElement>(null);',
    'const filteredUIDs = useMemo',
    'const stats = useMemo',
    'uid-stats-scroll',
    'visibleUIDs.map(entry => (',
    '{/* Card list */}',
    '{/* Stats bar */}',
    '{visibleCount < filteredUIDs.length && (',
)
missing = [s for s in required if s not in src]
if missing:
    sys.exit("XRIXUID PAGINATION: Frontend variant is incompatible: " + ", ".join(missing) + ". Apply existing Smooth UI v2 first; no files changed.")


def once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise ValueError(f"{label}: expected one occurrence, found {count}")
    return text.replace(old, new, 1)

try:
    dst = src
    dst = once(dst,
        'import { useState, useMemo, useEffect, useCallback, useRef, useDeferredValue } from "react";',
        'import { useState, useMemo, useEffect, useCallback, useDeferredValue } from "react";',
        'remove unused observer ref import')
    dst = once(dst, 'const [visibleCount, setVisibleCount] = useState(24);\n  const sentinelRef = useRef<HTMLDivElement>(null);',
        'const [currentPage, setCurrentPage] = useState(1);', 'replace rendering state')
    dst = once(dst, '\nexport default function Home({ search }: { search: string }) {',
        '''
const PAGE_SIZE = 300;

function UIDPager({ page, pageCount, count, onPage }: {
  page: number;
  pageCount: number;
  count: number;
  onPage: (next: number) => void;
}) {
  const first = (page - 1) * PAGE_SIZE + 1;
  const last = Math.min(page * PAGE_SIZE, count);
  return (
    <nav aria-label="UID page navigation" className="flex flex-wrap items-center justify-between gap-2 rounded-xl border border-card-border bg-card/40 px-3 py-2.5">
      <span className="text-xs text-[var(--text-muted)]" aria-live="polite">
        {first.toLocaleString()}–{last.toLocaleString()} of {count.toLocaleString()} · Page {page}/{pageCount}
      </span>
      <div className="flex items-center gap-2">
        <button type="button" onClick={() => onPage(page - 1)} disabled={page <= 1}
          className="rounded-lg border border-card-border px-3 py-2 text-xs font-semibold text-[var(--text-primary)] disabled:opacity-35 disabled:cursor-not-allowed hover:bg-[var(--card-border)]"
          aria-label="Previous UID page">‹ Prev</button>
        <button type="button" onClick={() => onPage(page + 1)} disabled={page >= pageCount}
          className="rounded-lg border border-card-border px-3 py-2 text-xs font-semibold text-[var(--text-primary)] disabled:opacity-35 disabled:cursor-not-allowed hover:bg-[var(--card-border)]"
          aria-label="Next UID page">Next ›</button>
      </div>
    </nav>
  );
}

export default function Home({ search }: { search: string }) {''', 'insert standalone pager')

    # Replace only the incremental loading block; preserve search/prefix/status filtering.
    begin = dst.index('  // A smaller first paint means less layout / image work on slower Android phones.')
    end = dst.index('  const stats = useMemo', begin)
    dst = dst[:begin] + '''  // XRX_UID_PAGER_V1: render no more than 300 cards on any single page.
  useEffect(() => { setCurrentPage(1); }, [search, uidPrefix, statusFilter]);
  const pageCount = Math.max(1, Math.ceil(filteredUIDs.length / PAGE_SIZE));
  const safePage = Math.min(currentPage, pageCount);
  const visibleUIDs = useMemo(() =>
    filteredUIDs.slice((safePage - 1) * PAGE_SIZE, safePage * PAGE_SIZE),
    [filteredUIDs, safePage]
  );
  const goToPage = useCallback((next: number) => {
    setCurrentPage(Math.max(1, Math.min(pageCount, next)));
    document.getElementById("xrx-uid-pager-top")?.scrollIntoView({ behavior: "smooth", block: "start" });
  }, [pageCount]);

''' + dst[end:]

    old_class = 'className="flex items-center justify-between surface-card border border-card-border rounded-xl px-3 py-2.5 text-xs font-mono gap-2 shadow-sm"'
    new_class = 'className="flex flex-wrap items-center justify-between surface-card border border-card-border rounded-2xl px-3 py-4 min-h-[120px] text-xs font-mono gap-3 shadow-sm"'
    dst = once(dst, old_class, new_class, 'enlarge existing stats panel')
    dst = once(dst,
        'className="uid-stats-scroll min-w-0 flex-1 flex items-center gap-3 overflow-x-auto whitespace-nowrap hide-scrollbar"',
        'className="uid-stats-scroll min-w-[170px] flex-1 flex flex-wrap items-center gap-x-3 gap-y-2"',
        'allow existing stats to wrap instead of clipping')

    stats_start = dst.index('      {/* Stats bar */}')
    stats_end = dst.index('      {/* UID Prefix Separator', stats_start)
    stats_chunk = dst[stats_start:stats_end]
    stats_closing = '\n      </div>\n\n'
    if not stats_chunk.endswith(stats_closing):
        raise ValueError('stats panel closing tag changed')
    quick_tabs = '''
          <div className="w-full grid grid-cols-4 gap-1.5 border-t border-card-border pt-3" aria-label="UID status pages">
            {([
              { key: "all", label: "All", count: stats.total },
              { key: "success", label: "Success", count: stats.success },
              { key: "error", label: "Failed", count: stats.error },
              { key: "pending", label: "Pending", count: stats.pending },
            ] as const).map(tab => (
              <button key={tab.key} type="button" onClick={() => setStatusFilter(tab.key)}
                aria-pressed={statusFilter === tab.key}
                className={`flex flex-col items-center justify-center min-w-0 rounded-lg border px-1 py-2 text-[11px] transition-colors ${
                  statusFilter === tab.key
                    ? "border-[var(--primary)] bg-[var(--primary)]/15 text-[var(--text-primary)]"
                    : "border-card-border text-[var(--text-muted)] hover:bg-[var(--card-border)]"
                }`}>
                <span className="font-semibold">{tab.label}</span>
                <span className="font-mono text-[10px]">{tab.count.toLocaleString()}</span>
              </button>
            ))}
          </div>'''
    stats_chunk = stats_chunk[:-len(stats_closing)] + quick_tabs + stats_closing
    dst = dst[:stats_start] + stats_chunk + dst[stats_end:]

    top_pager = '''      {filteredUIDs.length > 0 && (
        <div id="xrx-uid-pager-top" className="scroll-mt-16">
          <UIDPager page={safePage} pageCount={pageCount} count={filteredUIDs.length} onPage={goToPage} />
        </div>
      )}

      {/* Card list */}'''
    dst = once(dst, '      {/* Card list */}', top_pager, 'top pagination')

    loading_re = re.compile(r'          \{visibleCount < filteredUIDs\.length && \(\s*<div ref=\{sentinelRef\}.*?</div>\s*\)\}', re.S)
    if len(loading_re.findall(dst)) != 1:
        raise ValueError('load-more sentinel was not found exactly once')
    dst = loading_re.sub('''          {filteredUIDs.length > 0 && (
            <UIDPager page={safePage} pageCount={pageCount} count={filteredUIDs.length} onPage={goToPage} />
          )}''', dst, count=1)

    assert dst.count('XRX_UID_PAGER_V1') == 1
    assert dst.count('<UIDPager page={safePage}') == 2
    assert 'const [visibleCount' not in dst and 'sentinelRef' not in dst
    assert dst.count('setStatusFilter(') >= src.count('setStatusFilter(')
    assert dst.count('visibleUIDs.map(entry => (') == 1
except (ValueError, AssertionError) as exc:
    sys.exit(f'XRIXUID PAGINATION: Source differs from expected version: {exc}. No files changed.')

if mode == "check":
    print('XRIXUID PAGINATION: Compatible Smooth UI v2 detected; patch passes source checks.')
    sys.exit(0)

backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
backup = backup_dir / f'home-{datetime.now():%Y%m%d-%H%M%S}-{__import__("os").getpid()}.tsx'
backup.write_text(src, encoding='utf-8')
backup.chmod(0o600)
(backup_dir / 'latest').write_text(str(backup) + '\n', encoding='utf-8')

# Atomic file swap; backups and the rest of XRIXUID remain untouched.
with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=file_path.parent, prefix='.home-pagination-', delete=False) as fp:
    fp.write(dst)
    temp = pathlib.Path(fp.name)
temp.chmod(file_path.stat().st_mode & 0o777)
temp.replace(file_path)
print('XRIXUID PAGINATION: Installed. Stats panel enlarged; status tabs and 300-card pagination added.')
print(f'XRIXUID PAGINATION: Previous UI backed up to {backup}')
print('XRIXUID PAGINATION: No API, database, UID data, card behavior or other UI files changed.')
print('Refresh http://127.0.0.1:3000 ; if necessary restart the frontend.')
PY
