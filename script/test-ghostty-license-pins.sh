#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT_DIR/script/check_ghostty_license_pins.sh"
FIXTURE_DIR="$(mktemp -d)"
FIXTURE_PIN="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
trap 'trash "$FIXTURE_DIR" 2>/dev/null || find "$FIXTURE_DIR" -depth -delete' EXIT

write_manifest() {
  local pin="$1"
  printf '# ghostty_pin=%s\n' "$pin" > "$FIXTURE_DIR/manifest.tsv"
}

write_readme() {
  local pin="$1"
  printf '| Ghostty | `%s` | `Ghostty/LICENSE` |\n' "$pin" > "$FIXTURE_DIR/README.md"
}

write_integration_doc() {
  local pin="$1"
  printf -- '- Current pin: `%s` (untagged `origin/main`, post-`v1.3.1`)\n' "$pin" \
    > "$FIXTURE_DIR/ghostty-integration.md"
}

write_vendor_readme() {
  local pin="$1"
  printf -- '- `vendor/ghostty/` — git submodule pinned to `%s`.\n' "$pin" \
    > "$FIXTURE_DIR/vendor-README.md"
}

run_check() {
  AWESOMUX_GHOSTTY_LICENSE_MANIFEST="$FIXTURE_DIR/manifest.tsv" \
  AWESOMUX_GHOSTTY_LICENSE_README="$FIXTURE_DIR/README.md" \
  AWESOMUX_GHOSTTY_INTEGRATION_DOC="$FIXTURE_DIR/ghostty-integration.md" \
  AWESOMUX_GHOSTTY_VENDOR_README="$FIXTURE_DIR/vendor-README.md" \
  AWESOMUX_GHOSTTY_LICENSE_PIN="$FIXTURE_PIN" \
    "$CHECK"
}

expect_failure() {
  local expected="$1"
  if output="$(run_check 2>&1)"; then
    echo "expected failure containing: $expected" >&2
    exit 1
  fi
  grep -Fq "$expected" <<< "$output" || {
    echo "failure did not contain '$expected': $output" >&2
    exit 1
  }
}

write_manifest "$FIXTURE_PIN"
write_readme "$FIXTURE_PIN"
write_integration_doc "$FIXTURE_PIN"
write_vendor_readme "$FIXTURE_PIN"
run_check >/dev/null

write_manifest 0000000000000000000000000000000000000001
expect_failure "audit manifest pins 0000000000000000000000000000000000000001"

write_manifest "$FIXTURE_PIN"
write_readme 0000000000000000000000000000000000000002
write_integration_doc "$FIXTURE_PIN"
write_vendor_readme "$FIXTURE_PIN"
expect_failure "license README pins 0000000000000000000000000000000000000002"

write_manifest "$FIXTURE_PIN"
write_readme "$FIXTURE_PIN"
write_integration_doc 0000000000000000000000000000000000000003
write_vendor_readme "$FIXTURE_PIN"
expect_failure "ghostty integration doc pins 0000000000000000000000000000000000000003"

write_manifest "$FIXTURE_PIN"
write_readme "$FIXTURE_PIN"
write_integration_doc "$FIXTURE_PIN"
write_vendor_readme 0000000000000000000000000000000000000004
expect_failure "vendor README pins 0000000000000000000000000000000000000004"

echo "Ghostty license pin fixture tests passed."
