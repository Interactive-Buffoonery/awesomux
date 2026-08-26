#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT_DIR/script/check_ghostty_third_party_licenses.sh"
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

mkdir -p "$FIXTURE_DIR/licenses/Example"
printf 'int example(void) { return 0; }\n' > "$FIXTURE_DIR/example.c"
xcrun clang -c "$FIXTURE_DIR/example.c" -o "$FIXTURE_DIR/example.o"
touch "$FIXTURE_DIR/licenses/Example/LICENSE"
xcrun ar rcs "$FIXTURE_DIR/test.a" "$FIXTURE_DIR/example.o"
xcrun ar t "$FIXTURE_DIR/test.a" | LC_ALL=C sort -u > "$FIXTURE_DIR/members"
count="$(wc -l < "$FIXTURE_DIR/members" | tr -d ' ')"
digest="$(shasum -a 256 "$FIXTURE_DIR/members" | awk '{print $1}')"

write_manifest() {
  local pin="$1"
  local member="$2"
  local license="$3"
  {
    echo "# ghostty_pin=$pin"
    echo "# archive_member_count=$count"
    echo "# archive_members_sha256=$digest"
    printf 'Example\t1.0 / fixture\t%s\t%s\n' "$member" "$license"
  } > "$FIXTURE_DIR/manifest.tsv"
}

run_check() {
  AWESOMUX_GHOSTTY_LICENSE_MANIFEST="$FIXTURE_DIR/manifest.tsv" \
  AWESOMUX_GHOSTTY_LICENSE_ARCHIVE="$FIXTURE_DIR/test.a" \
  AWESOMUX_GHOSTTY_LICENSE_ROOT="$FIXTURE_DIR/licenses" \
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

write_manifest fixture-pin example.o Example/LICENSE
run_check >/dev/null

write_manifest stale-pin example.o Example/LICENSE
expect_failure "Ghostty pin changed"

write_manifest fixture-pin missing.o Example/LICENSE
expect_failure "representative member is absent"

write_manifest fixture-pin example.o Example/MISSING
expect_failure "license is missing"

printf 'int extra(void) { return 0; }\n' > "$FIXTURE_DIR/extra.c"
xcrun clang -c "$FIXTURE_DIR/extra.c" -o "$FIXTURE_DIR/extra.o"
xcrun ar rcs "$FIXTURE_DIR/test.a" "$FIXTURE_DIR/extra.o"
write_manifest fixture-pin example.o Example/LICENSE
expect_failure "archive member count changed"

echo "GhosttyKit third-party license audit fixture tests passed."
