#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT_DIR/Resources/Localizable.xcstrings"
CHECK_ONLY=false

if [[ "${1:-}" == "--check" && $# -eq 1 ]]; then
  CHECK_ONLY=true
elif (( $# != 0 )); then
  echo "usage: $0 [--check]" >&2
  exit 2
fi

if ! command -v trash >/dev/null 2>&1; then
  echo "error: trash is required to clean the temporary extraction directory" >&2
  exit 1
fi

EXTRACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/awesomux-localization.XXXXXX")"
trap 'trash "$EXTRACT_DIR"' EXIT

SYNC_CATALOG="$CATALOG"
if [[ "$CHECK_ONLY" == true ]]; then
  SYNC_CATALOG="$EXTRACT_DIR/Localizable.xcstrings"
  cp "$CATALOG" "$SYNC_CATALOG"
fi

source_files=()
while IFS= read -r file; do
  source_files+=("$file")
done < <(cd "$ROOT_DIR" && rg --files Sources -g '*.swift')

cd "$ROOT_DIR"
xcrun xcstringstool extract \
  --modern-localizable-strings \
  --SwiftUI \
  --omit-empty-stringsdata \
  --output-directory "$EXTRACT_DIR" \
  "${source_files[@]}"

shopt -s nullglob
stringsdata=("$EXTRACT_DIR"/*.stringsdata)
if (( ${#stringsdata[@]} == 0 )); then
  echo "error: string extraction produced no .stringsdata files" >&2
  exit 1
fi
xcrun xcstringstool sync "$SYNC_CATALOG" --stringsdata "${stringsdata[@]}"
xcrun xcstringstool print "$SYNC_CATALOG" >/dev/null

if [[ "$CHECK_ONLY" == true ]] && ! cmp -s "$CATALOG" "$SYNC_CATALOG"; then
  echo "error: Resources/Localizable.xcstrings is stale; run script/update_string_catalog.sh" >&2
  diff -u \
    --label Resources/Localizable.xcstrings \
    --label regenerated/Localizable.xcstrings \
    "$CATALOG" "$SYNC_CATALOG" || true
  exit 1
fi
