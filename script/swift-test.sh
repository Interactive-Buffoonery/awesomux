#!/usr/bin/env bash
#
# swift-test.sh — `swift test` with the worktree-aware Ghostty preflight.
#
# `swift test` does not call build_and_run.sh, so a fresh git worktree fails
# at module-resolution time with "umbrella header not found." Run this wrapper
# instead — it ensures .build/ghostty is populated (symlinked from the parent
# checkout in worktrees, or rebuilt) before invoking swift test.

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT_DIR/script/ensure_ghostty_artifacts.sh"
cd "$ROOT_DIR"
exec swift test "$@"
