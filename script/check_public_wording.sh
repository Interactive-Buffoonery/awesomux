#!/usr/bin/env bash
# Greps the public source surface for internal wording: reviewer/persona
# names, maintainer emails, and real home-directory paths (the AGENTS.md
# public-surface wording rule). The patterns live in
# script/internal-wording-patterns.txt, which is excluded from the public
# seed — when that file is absent (a public checkout) this check is a no-op.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PATTERNS_FILE="script/internal-wording-patterns.txt"
if [[ ! -f "$PATTERNS_FILE" ]]; then
    echo "check_public_wording: $PATTERNS_FILE absent (public checkout); skipping."
    exit 0
fi

PUBLIC_SURFACE_PATHS=(
    Sources
    Tests
    AGENTS.md
    CLAUDE.md
    CONTEXT.md
    CONTRIBUTING.md
    README.md
    .github/pull_request_template.md
    docs/contributing-ai-research.md
)

# -w so short names only match as whole words, not inside identifiers.
matches="$(grep -RInwE \
    -f <(grep -Ev '^(#|$)' "$PATTERNS_FILE") \
    "${PUBLIC_SURFACE_PATHS[@]}" || true)"

if [[ -n "$matches" ]]; then
    echo "check_public_wording: internal wording found in the public surface:" >&2
    echo "$matches" >&2
    exit 1
fi
echo "check_public_wording: clean."
