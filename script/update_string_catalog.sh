#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT_DIR/Resources/Localizable.xcstrings"
EXTRACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/awesomux-localization.XXXXXX")"

if ! command -v trash >/dev/null 2>&1; then
  echo "error: trash is required to clean the temporary extraction directory" >&2
  exit 1
fi
trap 'trash "$EXTRACT_DIR"' EXIT

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
xcrun xcstringstool sync "$CATALOG" --stringsdata "${stringsdata[@]}"
xcrun xcstringstool print "$CATALOG" >/dev/null
