#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

"$ROOT_DIR/script/check_public_wording.sh"
"$ROOT_DIR/script/check_public_seed_source.sh"
"$ROOT_DIR/script/check_plural_guards.sh"
"$ROOT_DIR/script/test-review-automation.sh"
"$ROOT_DIR/script/check_ghostty_archive_drift.sh"
"$ROOT_DIR/script/agent-hooks/test-awesomux-agent-event.sh"
# Sidebar tint/status chrome contrast (F44). Cheap pure-Python gate; run
# before the Swift suite so token drift fails fast without a full build.
python3 "$ROOT_DIR/script/check_tint_contrast.py"
"$ROOT_DIR/script/swift-test.sh"
"$ROOT_DIR/script/build_and_run.sh" --verify
