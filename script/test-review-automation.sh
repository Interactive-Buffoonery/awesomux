#!/usr/bin/env bash
# Runs the pure trust-boundary tests for review automation.
# These Node fixtures are cheap enough for preflight and Linux CI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v node >/dev/null 2>&1; then
    echo "test-review-automation: node is required" >&2
    exit 1
fi

echo "test-review-automation: OpenCode review trust boundaries"
node --test \
    .github/actions/run-opencode/test/summarize-log.test.mjs \
    .github/scripts/test/compute-review-guards.test.mjs \
    .github/scripts/test/extract-opencode-review.test.mjs \
    .github/scripts/test/homebrew-cask-workflow.test.mjs \
    .github/scripts/test/native-ci-workflow.test.mjs \
    .github/scripts/test/opencode-review-trust-boundary.test.mjs \
    .github/scripts/test/parse-review-findings.test.mjs \
    .github/scripts/test/public-pr-workflows.test.mjs \
    .github/scripts/test/update-homebrew-cask.test.mjs \
    .github/scripts/test/validate-pr-body.test.mjs
bash .github/actions/run-opencode/test/guard_test.sh
bash .github/actions/run-opencode/test/direct_run_test.sh

echo "test-review-automation: all passed."
