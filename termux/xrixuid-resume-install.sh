#!/data/data/com.termux/files/usr/bin/bash
# Install verified XRIXUID Chrome resume/pager fix from GitHub main; no DB changes.
set -Eeuo pipefail
RAW="https://raw.githubusercontent.com/parvez-devs/uidhub/main/termux/xrixuid-fix-chrome-resume.sh.gz.b64"
TARGET="$HOME/xrixuid-fix-chrome-resume.sh"
SHA="1fc39ee0a587265742ff89f6b6ab362cb51cadea9058f09ed770d68e3ce0d1fe"
for tool in curl base64 gzip sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing command: $tool" >&2; exit 1; }
done
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 3 "$RAW" -o "$TMP/patch.gz.b64"
base64 -d "$TMP/patch.gz.b64" | gzip -dc > "$TMP/installer.sh"
printf '%s  %s\n' "$SHA" "$TMP/installer.sh" | sha256sum -c -
cp "$TMP/installer.sh" "$TARGET"
bash "$TARGET" "${1:-install}"
