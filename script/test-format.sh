#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_PATH="$ROOT_DIR/Sources/FormatterGuardrailScriptTest.swift"

cleanup() {
    unlink "$FIXTURE_PATH" 2>/dev/null || true
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

if "$ROOT_DIR/script/format.sh" >/dev/null 2>&1; then
    echo "error: format write mode accepted an empty file list" >&2
    exit 1
fi

echo "Formatter guardrail tests passed"
