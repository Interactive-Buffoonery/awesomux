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
# Captured rather than piped: `format.sh | grep -q` runs under pipefail, and
# grep -q exits on first match, so format.sh can take SIGPIPE and fail the
# pipeline on passing behaviour. Anchored on the full summary, since a bare
# '1 unchanged' also matches '11 unchanged'.
skip_output="$(FORMAT_LINT_BASE=HEAD "$TEMP_REPO/script/format.sh" \
    "$TEMP_REPO/Sources/ExistingFormattingDebt.swift")"
if [[ "$skip_output" != *"0 changed-range, 0 whole-file, 1 with no formattable lines"* ]]; then
    echo "error: write mode did not skip a file with no changed lines" >&2
    exit 1
fi
if ! git -C "$TEMP_REPO" diff --quiet; then
    echo "error: write mode modified a file with no changed lines" >&2
    exit 1
fi

# A range starting at LINE 1. awk's uninitialised `offset` is 0 in arithmetic
# but the empty string in concatenation, so this emitted `:17` instead of
# `0:17`; swift-format exits 64 and set -e killed the run. Every other fixture
# in this file appends at EOF, which is exactly why it shipped green.
printf '// added first line\nstruct ExistingFormattingDebt {\n  // em dash — arrow → naïve\n  let value: Int\n}\n' \
    > "$TEMP_REPO/Sources/ExistingFormattingDebt.swift"
FORMAT_LINT_BASE=HEAD "$TEMP_REPO/script/format.sh" \
    "$TEMP_REPO/Sources/ExistingFormattingDebt.swift" >/dev/null
if ! grep -qx '  let value: Int' "$TEMP_REPO/Sources/ExistingFormattingDebt.swift"; then
    echo "error: line-1 range formatting rewrote committed debt" >&2
    exit 1
fi
git -C "$TEMP_REPO" checkout -q -- Sources/ExistingFormattingDebt.swift

# A RELATIVE path from a subdirectory. `relative_swift_path` resolves against
# $PWD, so a `cd "$ROOT_DIR"` placed above validation re-anchors every relative
# argument to the repo root — rejecting this outright, and silently formatting
# a same-named file in the wrong checkout when one exists.
mkdir -p "$TEMP_REPO/Sources/Nested"
printf 'struct Nested {\n      let deep:Int = 1\n}\n' > "$TEMP_REPO/Sources/Nested/Deep.swift"
(
    cd "$TEMP_REPO/Sources/Nested"
    FORMAT_LINT_BASE=HEAD "$TEMP_REPO/script/format.sh" Deep.swift >/dev/null
)
if ! grep -qx '    let deep: Int = 1' "$TEMP_REPO/Sources/Nested/Deep.swift"; then
    echo "error: write mode rejected a relative path from a subdirectory" >&2
    exit 1
fi

# A file with NO trailing newline. Range scoping deliberately stops before the
# line terminator, which also meant it could never add a missing one: write mode
# reported success, lint failed [AddLines], and re-running changed nothing.
printf 'struct NoNewline {\n      let z:Int = 1\n}' > "$TEMP_REPO/Sources/Nested/NoNewline.swift"
FORMAT_LINT_BASE=HEAD "$TEMP_REPO/script/format.sh" \
    "$TEMP_REPO/Sources/Nested/NoNewline.swift" >/dev/null
if [[ -n "$(tail -c 1 "$TEMP_REPO/Sources/Nested/NoNewline.swift")" ]]; then
    echo "error: write mode left a file without a trailing newline" >&2
    exit 1
fi

# A RENAMED file. A per-path `git diff -- <path>` cannot detect a rename, so the
# file came back as an addition and its whole body became one changed range —
# reformatting every line of committed drift, the exact blast radius this
# scoping exists to prevent.
git -C "$TEMP_REPO" add -A
git -C "$TEMP_REPO" \
    -c user.name='Formatter Guardrail Test' \
    -c user.email='formatter-guardrail@example.com' \
    commit -qm 'rename fixture base'
git -C "$TEMP_REPO" mv Sources/ExistingFormattingDebt.swift Sources/RenamedDebt.swift
# APPEND only. Rewriting the body would put the debt line inside a genuinely
# changed range, and the assertion would then be testing the fixture rather
# than rename detection.
printf '\nstruct FreshAfterRename {\n      let fresh:Int = 2\n}\n' \
    >> "$TEMP_REPO/Sources/RenamedDebt.swift"
FORMAT_LINT_BASE=HEAD "$TEMP_REPO/script/format.sh" \
    "$TEMP_REPO/Sources/RenamedDebt.swift" >/dev/null
if ! grep -qx '  let value: Int' "$TEMP_REPO/Sources/RenamedDebt.swift"; then
    echo "error: formatting a renamed file rewrote its committed debt" >&2
    exit 1
fi
if ! grep -qx '    let fresh: Int = 2' "$TEMP_REPO/Sources/RenamedDebt.swift"; then
    echo "error: formatting a renamed file skipped its changed lines" >&2
    exit 1
fi

# Write mode must still work where there is no history to diff against — an
# all-untracked batch takes the whole-file branch and needs no base ref. Eager
# resolution made this exit 2 blaming an environment variable nobody set.
NO_COMMIT_REPO="$(mktemp -d "${TMPDIR:-/tmp}/awesomux-format-nocommit.XXXXXX")"
mkdir -p "$NO_COMMIT_REPO/script" "$NO_COMMIT_REPO/Sources"
cp "$ROOT_DIR/.swift-format" "$ROOT_DIR/.swift-format-version" "$NO_COMMIT_REPO/"
cp "$ROOT_DIR/script/format.sh" "$NO_COMMIT_REPO/script/"
git -C "$NO_COMMIT_REPO" init -q
printf 'struct Fresh {\n      let v:Int = 1\n}\n' > "$NO_COMMIT_REPO/Sources/Fresh.swift"
"$NO_COMMIT_REPO/script/format.sh" "$NO_COMMIT_REPO/Sources/Fresh.swift" >/dev/null
if ! grep -qx '    let v: Int = 1' "$NO_COMMIT_REPO/Sources/Fresh.swift"; then
    echo "error: write mode failed in a repository with no commits" >&2
    exit 1
fi
if command -v trash >/dev/null 2>&1; then
    trash "$NO_COMMIT_REPO" 2>/dev/null || find "$NO_COMMIT_REPO" -depth -delete 2>/dev/null || true
else
    find "$NO_COMMIT_REPO" -depth -delete 2>/dev/null || true
fi

if "$ROOT_DIR/script/format.sh" >/dev/null 2>&1; then
    echo "error: format write mode accepted an empty file list" >&2
    exit 1
fi

echo "Formatter guardrail tests passed"
