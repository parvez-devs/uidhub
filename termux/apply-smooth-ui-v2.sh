#!/data/data/com.termux/files/usr/bin/bash
# XRIXUID Smooth UI v2: frontend-only patch; original Termux launcher stays unchanged.
set -Eeuo pipefail
ROOT="$HOME/projects/xrixuid"
SRC="https://raw.githubusercontent.com/parvez-devs/uidhub/main/termux/smooth-ui-v2.patch.gz.b64"
SHA="6ed452f998fc191c7f19915e87009150fd72ab8a7e57da2f7a91c267200d7fdc"
FILES=(
  'artifacts/uid-web/src/App.tsx'
  'artifacts/uid-web/src/pages/home.tsx'
  'artifacts/uid-web/src/components/uid-card.tsx'
  'artifacts/uid-web/src/index.css'
)
fail() { echo "XRIXUID Smooth UI update failed: $*" >&2; exit 1; }
command -v pkg >/dev/null || fail "Run from normal Termux, not Debian."
for cmd in curl base64 gzip patch sha256sum; do
  command -v "$cmd" >/dev/null || fail "Missing $cmd; install curl, gzip, patch, coreutils."
done
[ -f "$ROOT/package.json" ] || fail "Existing project not found: $ROOT"
for f in "${FILES[@]}"; do [ -f "$ROOT/$f" ] || fail "Source missing: $f"; done
if grep -Fq 'XRIXUID-SMOOTH-V2' "$ROOT/artifacts/uid-web/src/index.css"; then
  echo "✅ Smooth UI v2 already installed."
  exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 3 "$SRC" -o "$TMP/patch.gz.b64"
base64 -d "$TMP/patch.gz.b64" | gzip -dc > "$TMP/update.patch" || fail "Could not unpack patch."
printf '%s  %s\n' "$SHA" "$TMP/update.patch" | sha256sum -c --status || fail "Patch checksum incorrect."
(cd "$ROOT" && patch --dry-run --batch --forward --fuzz=0 -p1 < "$TMP/update.patch") || fail "Current UI source does not match. No changes made."
BACKUP="$HOME/xrixuid-ui-backups/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$BACKUP"
for f in "${FILES[@]}"; do
  mkdir -p "$BACKUP/$(dirname "$f")"
  cp -p "$ROOT/$f" "$BACKUP/$f"
done
if ! (cd "$ROOT" && patch --batch --forward --fuzz=0 -p1 < "$TMP/update.patch"); then
  for f in "${FILES[@]}"; do cp -p "$BACKUP/$f" "$ROOT/$f"; done
  fail "Patch failed. Restored 4 frontend files from backup."
fi
echo "✅ Smooth UI v2 installed."
echo "✅ Backup: $BACKUP"
echo "✅ No changes to API, database, original installer, or Cloudflare Tunnel."
echo "Refresh the dashboard. If needed, restart only the frontend service."
