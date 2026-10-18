#!/usr/bin/env bash
set -euo pipefail

checks_only=false
if [[ "$#" -eq 1 && "$1" == --checks-only ]]; then
    checks_only=true
elif [[ "$#" -ne 0 ]]; then
    echo "Usage: ./script/preflight.sh [--checks-only]" >&2
    exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

"$ROOT_DIR/script/check_public_wording.sh"
"$ROOT_DIR/script/check_public_seed_source.sh"
"$ROOT_DIR/script/check_plural_guards.sh"
"$ROOT_DIR/script/update_string_catalog.sh" --check
"$ROOT_DIR/script/check_test_waits.sh"
"$ROOT_DIR/script/test-format.sh"
"$ROOT_DIR/script/format.sh" --lint
"$ROOT_DIR/script/test-ci-automation.sh"
"$ROOT_DIR/script/check_ghostty_license_pins.sh"
"$ROOT_DIR/script/test.sh" all
if [[ "$checks_only" == true ]]; then
    echo "Preflight checks passed (checks-only); staged-app build, signing, and launch verification were not run."
else
    "$ROOT_DIR/script/build_and_run.sh" --verify
fi
