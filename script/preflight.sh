#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

"$ROOT_DIR/script/check_public_wording.sh"
"$ROOT_DIR/script/check_public_seed_source.sh"
"$ROOT_DIR/script/check_plural_guards.sh"
"$ROOT_DIR/script/update_string_catalog.sh" --check
"$ROOT_DIR/script/test-test-wait-guard.sh"
python3 -B "$ROOT_DIR/script/test_swift_test_report.py"
"$ROOT_DIR/script/check_test_waits.sh"
"$ROOT_DIR/script/test-format.sh"
"$ROOT_DIR/script/format.sh" --lint
"$ROOT_DIR/script/test-review-automation.sh"
"$ROOT_DIR/script/check_ghostty_archive_drift.sh"
python3 "$ROOT_DIR/script/test_prepare_ghostty_source.py"
"$ROOT_DIR/script/test-ghostty-license-pins.sh"
"$ROOT_DIR/script/check_ghostty_license_pins.sh"
"$ROOT_DIR/script/test-ghostty-third-party-licenses.sh"
"$ROOT_DIR/script/agent-hooks/test-awesomux-agent-event.sh"
"$ROOT_DIR/script/test.sh" all
"$ROOT_DIR/script/build_and_run.sh" --verify
