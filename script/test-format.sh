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
printf 'struct ExistingFormattingDebt {\n  let value: Int\n}\n' \
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

if "$ROOT_DIR/script/format.sh" >/dev/null 2>&1; then
    echo "error: format write mode accepted an empty file list" >&2
    exit 1
fi

echo "Formatter guardrail tests passed"
