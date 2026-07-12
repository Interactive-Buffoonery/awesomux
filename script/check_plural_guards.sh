#!/usr/bin/env bash
# Fails when Sources/awesoMux adds English singular/plural ternaries for
# count-dependent UI / accessibility copy (AGENTS.md localization rule, F38).
# Count-dependent strings must route through Localizable.stringsdict via
# LocalizedPluralStrings — not `count == 1 ? ... : ...` switches.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SCAN_ROOT="Sources/awesoMux"

# Patterns that encode English singular/plural inflection in source.
# Keep these tight: bare `count == 1` for control flow is fine.
# [[:space:]] must match newlines so standard multiline Swift formatting is
# caught (e.g. `count == 1\n    ? "item"\n    : "items"`). Requires rg -U.
PATTERN='(==[[:space:]]*1[[:space:]]*\?[[:space:]]*""[[:space:]]*:[[:space:]]*"s"|==[[:space:]]*1[[:space:]]*\?[[:space:]]*"[^"]*"[[:space:]]*:[[:space:]]*"[^"]*")'

if ! command -v rg >/dev/null 2>&1; then
    echo "check_plural_guards: ripgrep (rg) is required" >&2
    exit 1
fi

# Prove multiline matching is active before trusting a clean scan. A one-line
# pattern would still pass this self-check; the multiline fixture fails the
# original line-scoped scan missed.
self_check_dir="$(mktemp -d "${TMPDIR:-/tmp}/check_plural_guards.XXXXXX")"
trap 'rm -rf "$self_check_dir"' EXIT
cat >"$self_check_dir/MultilinePluralFixture.swift" <<'SWIFT'
enum MultilinePluralFixture {
    static func noun(for count: Int) -> String {
        count == 1
            ? "item"
            : "items"
    }
}
SWIFT
if ! rg -qU --glob '*.swift' -e "$PATTERN" "$self_check_dir"; then
    echo "check_plural_guards: multiline self-check failed — pattern no longer catches" >&2
    echo "standard Swift formatting of count == 1 ? singular : plural." >&2
    exit 1
fi

matches="$(
    rg -nU --glob '*.swift' -e "$PATTERN" "$SCAN_ROOT" || true
)"

if [[ -n "$matches" ]]; then
    echo "check_plural_guards: English singular/plural ternaries found:" >&2
    printf '%s\n' "$matches" >&2
    echo >&2
    echo "Route count-dependent copy through LocalizedPluralStrings + Localizable.stringsdict." >&2
    exit 1
fi

echo "check_plural_guards: clean."
