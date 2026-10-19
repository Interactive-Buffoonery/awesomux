#!/usr/bin/env bash
# Runs the workflow tests for CI and release automation.
# These Node fixtures are cheap enough for preflight and Linux CI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v node >/dev/null 2>&1; then
    echo "test-ci-automation: node is required" >&2
    exit 1
fi

echo "test-ci-automation: CI and release workflow checks"
node --test .github/scripts/test/*.test.mjs

echo "test-ci-automation: all passed."
