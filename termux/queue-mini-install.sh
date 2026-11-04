#!/data/data/com.termux/files/usr/bin/bash
# XRIXUID queue UI-only installer. Download, verify, install/revert.
set -Eeuo pipefail
RAW='https://raw.githubusercontent.com/parvez-devs/uidhub/main/termux/queue-mini-header.sh.gz.b64'
TARGET="$HOME/queue-mini-header.sh"
SHA256='5171532c37a43f993cfe632c9450a1378cda8220d27a95f1ac5a892759e57ebc'
for cmd in curl base64 gzip sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing $cmd" >&2; exit 1; }
done
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fLsS --retry 3 "$RAW" -o "$TMP/script.b64"
base64 -d "$TMP/script.b64" | gzip -dc > "$TMP/queue-mini-header.sh"
printf '%s  %s\n' "$SHA256" "$TMP/queue-mini-header.sh" | sha256sum -c -
cp "$TMP/queue-mini-header.sh" "$TARGET"
bash "$TARGET" "${1:-install}"
