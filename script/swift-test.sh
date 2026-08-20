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

# A full Swift Testing run is not safe in one process. AppKit-heavy tests can
# exhaust libdispatch's thread soft limit while blocking suites occupy the
# cooperative executor. Keep this low-level wrapper for focused selections,
# but route the common no-argument full run through the isolated groups.
if [[ "$#" -eq 0 ]]; then
    exec "$ROOT_DIR/script/test.sh" all
fi

"$ROOT_DIR/script/ensure_ghostty_artifacts.sh"
cd "$ROOT_DIR"
exec swift test "$@"
