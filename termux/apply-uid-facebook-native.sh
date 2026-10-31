#!/data/data/com.termux/files/usr/bin/bash
# XRIXUID: tap UID text to open the installed official Facebook Android app.
# Frontend-only update; existing installer, backend, DB and Cloudflare are untouched.
set -Eeuo pipefail
MODE="${1:-install}"
ROOT="$HOME/projects/xrixuid"
CARD="$ROOT/artifacts/uid-web/src/components/uid-card.tsx"
BACKUP_DIR="$HOME/xrixuid-facebook-link-backups"
PATCH_URL="https://raw.githubusercontent.com/parvez-devs/uidhub/main/termux/uid-facebook-native.patch"
PATCH_SHA256="52e50b9bc509fcff443330e75ab8cd9cf9d8d3fbdefc6a64dce9f4090d8e595d"
fail() { printf '❌ XRIXUID: %s\n' "$*" >&2; exit 1; }

[ -f "$CARD" ] || fail "UID card source missing: $CARD"

if [ "$MODE" = rollback ]; then
  [ -s "$BACKUP_DIR/latest" ] || fail 'No backup was found.'
  SOURCE="$(cat "$BACKUP_DIR/latest")"
  case "$SOURCE" in "$BACKUP_DIR"/*) ;; *) fail 'Unexpected backup path.' ;; esac
  [ -f "$SOURCE" ] || fail 'Backup file missing.'
  cp -p "$SOURCE" "$CARD"
  echo '✅ Original UID click behavior restored. Refresh the dashboard.'
  exit 0
fi
[ "$MODE" = install ] || fail 'Use install or rollback.'

if grep -Fq 'intent://profile/' "$CARD"; then
  echo '✅ Facebook native UID link already installed.'
  exit 0
fi

for CMD in curl patch sha256sum; do
  command -v "$CMD" >/dev/null 2>&1 || fail "Missing '$CMD'. Run: pkg install curl patch coreutils -y"
done
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl --retry 3 -fsSL "$PATCH_URL" -o "$TMP/uid-facebook-native.patch" || fail 'Patch download failed.'
printf '%s  %s\n' "$PATCH_SHA256" "$TMP/uid-facebook-native.patch" | sha256sum -c --status || fail 'Patch checksum mismatch.'
(cd "$ROOT" && patch --batch --forward --fuzz=0 --dry-run -p1 < "$TMP/uid-facebook-native.patch") || fail 'Source differs from expected version. No changes made.'

mkdir -p "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/uid-card-$(date +%Y%m%d-%H%M%S)-$$.tsx"
cp -p "$CARD" "$BACKUP"
printf '%s\n' "$BACKUP" > "$BACKUP_DIR/latest"
if ! (cd "$ROOT" && patch --batch --forward --fuzz=0 -p1 < "$TMP/uid-facebook-native.patch"); then
  cp -p "$BACKUP" "$CARD"
  fail "Patch failed; original card restored from $BACKUP."
fi

echo '✅ UID text now opens the official Facebook Android app (no web fallback).'
echo '✅ The adjacent copy icon still copies the UID.'
echo "✅ Backup: $BACKUP"
echo '✅ Other UI, fetching, API, database, tunnel and original installer untouched.'
echo 'Refresh the dashboard (Vite dev will pick up this frontend source update).'
echo 'Rollback: bash ~/xrixuid-fb-native-update.sh rollback'
