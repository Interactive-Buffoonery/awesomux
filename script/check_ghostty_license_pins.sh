#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${AWESOMUX_GHOSTTY_LICENSE_MANIFEST:-$ROOT_DIR/script/ghostty-third-party-components.tsv}"
LICENSE_README="${AWESOMUX_GHOSTTY_LICENSE_README:-$ROOT_DIR/Resources/Licenses/README.md}"
INTEGRATION_DOC="${AWESOMUX_GHOSTTY_INTEGRATION_DOC:-$ROOT_DIR/docs/ghostty-integration.md}"
VENDOR_README="${AWESOMUX_GHOSTTY_VENDOR_README:-$ROOT_DIR/vendor/README.md}"

die() {
  echo "error: Ghostty license pin check: $*" >&2
  exit 1
}

[[ -f "$MANIFEST" ]] || die "audit manifest is missing: $MANIFEST"
[[ -f "$LICENSE_README" ]] || die "license README is missing: $LICENSE_README"
[[ -f "$INTEGRATION_DOC" ]] || die "ghostty integration doc is missing: $INTEGRATION_DOC"
[[ -f "$VENDOR_README" ]] || die "vendor README is missing: $VENDOR_README"

actual_pin="${AWESOMUX_GHOSTTY_LICENSE_PIN:-}"
if [[ -z "$actual_pin" ]]; then
  actual_pin="$(git -C "$ROOT_DIR" rev-parse HEAD:vendor/ghostty 2>/dev/null || true)"
fi
[[ -n "$actual_pin" ]] || die "could not resolve HEAD:vendor/ghostty"

manifest_pin="$(sed -nE 's/^# ghostty_pin=//p' "$MANIFEST")"
[[ -n "$manifest_pin" ]] || die "audit manifest has no Ghostty pin"
[[ "$manifest_pin" != *$'\n'* ]] || die "audit manifest has more than one Ghostty pin"
[[ "$manifest_pin" == "$actual_pin" ]] \
  || die "audit manifest pins $manifest_pin, but vendor/ghostty pins $actual_pin; rebuild and re-audit the archive"

readme_pin="$(awk -F '|' '
  $2 ~ /^[[:space:]]*Ghostty[[:space:]]*$/ {
    value = $3
    gsub(/[[:space:]`]/, "", value)
    print value
  }
' "$LICENSE_README")"
[[ -n "$readme_pin" ]] || die "license README has no Ghostty row"
[[ "$readme_pin" != *$'\n'* ]] || die "license README has more than one Ghostty row"
[[ "$readme_pin" == "$actual_pin" ]] \
  || die "license README pins $readme_pin, but vendor/ghostty pins $actual_pin; refresh the bundled Ghostty license"

integration_pin="$(sed -nE 's/^- Current pin: `([0-9a-f]{40})`.*/\1/p' "$INTEGRATION_DOC")"
[[ -n "$integration_pin" ]] || die "ghostty integration doc has no Current pin line"
[[ "$integration_pin" != *$'\n'* ]] || die "ghostty integration doc has more than one Current pin"
[[ "$integration_pin" == "$actual_pin" ]] \
  || die "ghostty integration doc pins $integration_pin, but vendor/ghostty pins $actual_pin; refresh the pin documentation"

vendor_readme_pin="$(sed -nE 's/.*pinned to `([0-9a-f]{40})`.*/\1/p' "$VENDOR_README")"
[[ -n "$vendor_readme_pin" ]] || die "vendor README has no Ghostty pin"
[[ "$vendor_readme_pin" != *$'\n'* ]] || die "vendor README has more than one Ghostty pin"
[[ "$vendor_readme_pin" == "$actual_pin" ]] \
  || die "vendor README pins $vendor_readme_pin, but vendor/ghostty pins $actual_pin; refresh the pin documentation"

echo "Ghostty license pins match vendor/ghostty ($actual_pin)."
