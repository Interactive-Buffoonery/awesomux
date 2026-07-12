#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=script/ghostty_link_archives.sh
source "$ROOT_DIR/script/ghostty_link_archives.sh"

EXPECTED_LIST="$(mktemp -t ghostty-archive-drift-expected)"
PACKAGE_LIST="$(mktemp -t ghostty-archive-drift-package)"
cleanup() {
  rm -f "$EXPECTED_LIST" "$PACKAGE_LIST"
}
trap cleanup EXIT

for archive in "${GHOSTTY_LINK_ARCHIVES[@]}"; do
  ghostty_link_archive_dest_path "$archive"
done | LC_ALL=C sort > "$EXPECTED_LIST"

sed -nE 's|.*"\.build/ghostty/(GhosttyKit\.xcframework/macos-arm64/[^"]+\.a)".*|\1|p' \
  "$ROOT_DIR/Package.swift" | LC_ALL=C sort > "$PACKAGE_LIST"

if ! cmp -s "$EXPECTED_LIST" "$PACKAGE_LIST"; then
  cat >&2 <<EOF
Ghostty archive list drift detected.

Update Package.swift linker flags and script/ghostty_link_archives.sh together.

Expected from script/ghostty_link_archives.sh:
EOF
  sed 's/^/  /' "$EXPECTED_LIST" >&2
  cat >&2 <<EOF

Found in Package.swift:
EOF
  sed 's/^/  /' "$PACKAGE_LIST" >&2
  exit 1
fi

echo "Ghostty archive list matches Package.swift"
