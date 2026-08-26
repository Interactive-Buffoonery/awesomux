#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${AWESOMUX_GHOSTTY_LICENSE_MANIFEST:-$ROOT_DIR/script/ghostty-third-party-components.tsv}"
ARCHIVE="${AWESOMUX_GHOSTTY_LICENSE_ARCHIVE:-$ROOT_DIR/.build/ghostty/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a}"
LICENSE_ROOT="${AWESOMUX_GHOSTTY_LICENSE_ROOT:-$ROOT_DIR/Resources/Licenses}"
BUILT_FROM_STAMP="${AWESOMUX_GHOSTTY_LICENSE_BUILT_FROM_STAMP:-$ROOT_DIR/.build/ghostty/.built-from-sha}"
ZIG_VERSION_STAMP="${AWESOMUX_GHOSTTY_LICENSE_ZIG_VERSION_STAMP:-$ROOT_DIR/.build/ghostty/.built-zig-version}"

die() {
  echo "error: GhosttyKit third-party license audit: $*" >&2
  exit 1
}

manifest_value() {
  local key="$1"
  sed -nE "s/^# ${key}=//p" "$MANIFEST" | head -n 1
}

[[ -f "$MANIFEST" ]] || die "manifest is missing: $MANIFEST"
[[ -f "$ARCHIVE" ]] || die "archive is missing: $ARCHIVE"

expected_pin="$(manifest_value ghostty_pin)"
expected_count="$(manifest_value archive_member_count)"
expected_digest="$(manifest_value archive_members_sha256)"
expected_zig_series="$(manifest_value zig_version_series)"
[[ -n "$expected_pin" && -n "$expected_count" && -n "$expected_digest" && -n "$expected_zig_series" ]] \
  || die "manifest metadata is incomplete"

actual_pin="${AWESOMUX_GHOSTTY_LICENSE_PIN:-}"
if [[ -z "$actual_pin" ]]; then
  actual_pin="$(git -C "$ROOT_DIR" rev-parse HEAD:vendor/ghostty 2>/dev/null || true)"
fi
[[ -n "$actual_pin" ]] || die "could not resolve HEAD:vendor/ghostty"
[[ "$actual_pin" == "$expected_pin" ]] \
  || die "Ghostty pin changed from $expected_pin to $actual_pin; rebuild and re-audit the archive"

[[ -f "$BUILT_FROM_STAMP" ]] || die "artifact Ghostty provenance stamp is missing: $BUILT_FROM_STAMP"
IFS= read -r built_from_pin < "$BUILT_FROM_STAMP" || true
built_from_pin="${built_from_pin%$'\r'}"
[[ "$built_from_pin" == "$expected_pin" ]] \
  || die "archive was built from Ghostty $built_from_pin, expected $expected_pin; rebuild before auditing"

[[ -f "$ZIG_VERSION_STAMP" ]] || die "artifact Zig provenance stamp is missing: $ZIG_VERSION_STAMP"
IFS= read -r built_with_zig < "$ZIG_VERSION_STAMP" || true
built_with_zig="${built_with_zig%$'\r'}"
[[ "$built_with_zig" == "$expected_zig_series".* ]] \
  || die "archive was built with Zig $built_with_zig, expected $expected_zig_series.x; rebuild and re-audit"

if command -v xcrun >/dev/null 2>&1; then
  AR=(xcrun ar)
elif command -v ar >/dev/null 2>&1; then
  AR=(ar)
else
  die "neither xcrun ar nor ar is available"
fi

members_file="$(mktemp)"
trap 'rm -f "$members_file"' EXIT
"${AR[@]}" t "$ARCHIVE" | LC_ALL=C sort > "$members_file"

actual_count="$(wc -l < "$members_file" | tr -d ' ')"
actual_digest="$(shasum -a 256 "$members_file" | awk '{print $1}')"
[[ "$actual_count" == "$expected_count" ]] \
  || die "archive member count changed from $expected_count to $actual_count; re-audit required"
[[ "$actual_digest" == "$expected_digest" ]] \
  || die "archive member inventory changed (expected $expected_digest, got $actual_digest); re-audit required"

component_count=0
while IFS=$'\t' read -r component source member license_paths extra; do
  [[ -z "$component" || "$component" == \#* ]] && continue
  [[ -n "$source" && -n "$member" && -n "$license_paths" && -z "${extra:-}" ]] \
    || die "malformed manifest row for $component"
  grep -Fxq "$member" "$members_file" \
    || die "$component representative member is absent: $member"

  IFS='|' read -r -a paths <<< "$license_paths"
  [[ "${#paths[@]}" -gt 0 ]] || die "$component has no license files"
  for path in "${paths[@]}"; do
    [[ -f "$LICENSE_ROOT/$path" ]] || die "$component license is missing: Resources/Licenses/$path"
  done
  component_count=$((component_count + 1))
done < "$MANIFEST"

[[ "$component_count" -gt 0 ]] || die "manifest contains no component rows"
echo "GhosttyKit third-party license audit passed ($component_count components, $actual_count archive members)."
