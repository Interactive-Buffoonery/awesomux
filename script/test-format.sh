#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_PATH="$ROOT_DIR/Sources/FormatterGuardrailScriptTest.swift"
TEMP_REPO="$(mktemp -d "${TMPDIR:-/tmp}/awesomux-format-test.XXXXXX")"
LINKED_REPO="$TEMP_REPO-linked"

cleanup() {
    unlink "$FIXTURE_PATH" 2>/dev/null || true
    unlink "$LINKED_REPO" 2>/dev/null || true
    if command -v trash >/dev/null 2>&1 && trash "$TEMP_REPO" 2>/dev/null; then
        return
    fi
    find "$TEMP_REPO" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

if [[ -e "$FIXTURE_PATH" ]]; then
    echo "error: formatter test fixture already exists: $FIXTURE_PATH" >&2
    exit 1
fi

printf 'struct FormatterGuardrailScriptTest {\n  let value: Int\n}\n' > "$FIXTURE_PATH"

if FORMAT_LINT_BASE=HEAD "$ROOT_DIR/script/format.sh" --lint >/dev/null 2>&1; then
    echo "error: format lint accepted an incorrectly indented changed line" >&2
    exit 1
fi

"$ROOT_DIR/script/format.sh" "$FIXTURE_PATH"
grep -qx '    let value: Int' "$FIXTURE_PATH"
FORMAT_LINT_BASE=HEAD "$ROOT_DIR/script/format.sh" --lint >/dev/null

mkdir -p "$TEMP_REPO/script" "$TEMP_REPO/Sources"
cp "$ROOT_DIR/.swift-format" "$TEMP_REPO/.swift-format"
cp "$ROOT_DIR/.swift-format-version" "$TEMP_REPO/.swift-format-version"
cp "$ROOT_DIR/script/format.sh" "$TEMP_REPO/script/format.sh"
printf 'darwin=0.0.0\nlinux=0.0.0\n' > "$TEMP_REPO/.swift-format-version"
if "$TEMP_REPO/script/format.sh" --lint >/dev/null 2>&1; then
    echo "error: format lint accepted a mismatched formatter version" >&2
    exit 1
fi
cp "$ROOT_DIR/.swift-format-version" "$TEMP_REPO/.swift-format-version"
# Multi-byte text above the eventual change, so the byte-offset conversion has
# something to get wrong. Note this asserts CONTENT INTEGRITY only: BSD awk
# counts bytes in every locale, so dropping format.sh's LC_ALL=C does not fail
# on macOS. The byte-vs-character divergence is GNU awk's, and only the Linux
# lane can catch it.
printf 'struct ExistingFormattingDebt {\n  // em dash — arrow → naïve\n  let value: Int\n}\n' \
    > "$TEMP_REPO/Sources/ExistingFormattingDebt.swift"
git -C "$TEMP_REPO" init -q
git -C "$TEMP_REPO" add .swift-format .swift-format-version script/format.sh Sources/ExistingFormattingDebt.swift
git -C "$TEMP_REPO" \
    -c user.name='Formatter Guardrail Test' \
    -c user.email='formatter-guardrail@example.com' \
    commit -qm 'test fixture'

printf '\nstruct ChangedFormattingIsValid {}\n' \
    >> "$TEMP_REPO/Sources/ExistingFormattingDebt.swift"
FORMAT_LINT_BASE=HEAD "$TEMP_REPO/script/format.sh" --lint >/dev/null

ln -s "$TEMP_REPO" "$LINKED_REPO"
"$LINKED_REPO/script/format.sh" \
    "$LINKED_REPO/Sources/ExistingFormattingDebt.swift"

# Write mode is range-scoped: a file carrying committed formatting debt must
# have ONLY its changed lines rewritten. Formatting whole files is what turned a
# 50-line change into a 264-line diff, twice, and buried the real edit.
printf '\nstruct RangeScopedTarget {\n      let deep: Int\n}\n' \
    >> "$TEMP_REPO/Sources/ExistingFormattingDebt.swift"
FORMAT_LINT_BASE=HEAD "$TEMP_REPO/script/format.sh" \
    "$TEMP_REPO/Sources/ExistingFormattingDebt.swift" >/dev/null
if ! grep -qx '    let deep: Int' "$TEMP_REPO/Sources/ExistingFormattingDebt.swift"; then
    echo "error: range-scoped write mode did not format the changed lines" >&2
    exit 1
fi
if ! grep -qx '  let value: Int' "$TEMP_REPO/Sources/ExistingFormattingDebt.swift"; then
    echo "error: range-scoped write mode rewrote committed debt outside the change" >&2
    exit 1
fi
if ! grep -qx '  // em dash — arrow → naïve' "$TEMP_REPO/Sources/ExistingFormattingDebt.swift"; then
    echo "error: byte-offset conversion corrupted multi-byte content" >&2
    exit 1
fi
if ! grep -qx 'struct RangeScopedTarget {' "$TEMP_REPO/Sources/ExistingFormattingDebt.swift"; then
    echo "error: range-scoped write mode mangled the file around the change" >&2
    exit 1
fi

# The change above runs to EOF, so its byte range ends at the last line. If that
# range includes the trailing newline, swift-format consumes it and the file it
# just wrote fails its own [AddLines] rule. Assert the newline survives, then
# assert lint agrees — write mode must never emit a file lint rejects.
if [[ "$(tail -c 1 "$TEMP_REPO/Sources/ExistingFormattingDebt.swift" | xxd -p)" != "0a" ]]; then
    echo "error: range-scoped write mode stripped the trailing newline at EOF" >&2
    exit 1
fi
if ! FORMAT_LINT_BASE=HEAD "$TEMP_REPO/script/format.sh" --lint >/dev/null 2>&1; then
    echo "error: range-scoped write mode produced a file its own lint rejects" >&2
    exit 1
fi

# A tracked file with nothing changed against the base is left entirely alone,
# so formatting an untouched path can never smuggle in drift repairs.
git -C "$TEMP_REPO" \
    -c user.name='Formatter Guardrail Test' \
    -c user.email='formatter-guardrail@example.com' \
    commit -qam 'range-scoped fixture'
FORMAT_LINT_BASE=HEAD "$TEMP_REPO/script/format.sh" \
    "$TEMP_REPO/Sources/ExistingFormattingDebt.swift" \
    | grep -q '1 unchanged' || {
    echo "error: write mode did not skip a file with no changed lines" >&2
    exit 1
}
if ! git -C "$TEMP_REPO" diff --quiet; then
    echo "error: write mode modified a file with no changed lines" >&2
    exit 1
fi

if "$ROOT_DIR/script/format.sh" >/dev/null 2>&1; then
    echo "error: format write mode accepted an empty file list" >&2
    exit 1
fi

echo "Formatter guardrail tests passed"
