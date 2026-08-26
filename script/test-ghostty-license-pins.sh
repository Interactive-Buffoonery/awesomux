#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT_DIR/script/check_ghostty_license_pins.sh"
FIXTURE_DIR="$(mktemp -d)"
trap 'trash "$FIXTURE_DIR" 2>/dev/null || find "$FIXTURE_DIR" -depth -delete' EXIT

write_manifest() {
  local pin="$1"
  printf '# ghostty_pin=%s\n' "$pin" > "$FIXTURE_DIR/manifest.tsv"
}

write_readme() {
  local pin="$1"
  printf '| Ghostty | `%s` | `Ghostty/LICENSE` |\n' "$pin" > "$FIXTURE_DIR/README.md"
}

run_check() {
  AWESOMUX_GHOSTTY_LICENSE_MANIFEST="$FIXTURE_DIR/manifest.tsv" \
  AWESOMUX_GHOSTTY_LICENSE_README="$FIXTURE_DIR/README.md" \
  AWESOMUX_GHOSTTY_LICENSE_PIN="fixture-pin" \
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

write_manifest fixture-pin
write_readme fixture-pin
run_check >/dev/null

write_manifest stale-manifest-pin
expect_failure "audit manifest pins stale-manifest-pin"

write_manifest fixture-pin
write_readme stale-readme-pin
expect_failure "license README pins stale-readme-pin"

echo "Ghostty license pin fixture tests passed."
