#!/usr/bin/env bash
# Unit test for the review-output guard in ../guard.sh.
#
# Sources the real guard helpers and runs them against fixtures captured from
# actual opencode-review runs (prefix-stripped to mirror the raw tee log).
# Run: bash .github/actions/run-opencode/test/guard_test.sh

set -uo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="$test_dir/fixtures"

# shellcheck source=.github/actions/run-opencode/guard.sh
. "$test_dir/../guard.sh"

failures=0

expect_opencode_unavailable() {
  local label="$1" fixture="$2" want="$3" got # want: match | miss
  if opencode_unavailable_detected "$fixture" >/dev/null 2>&1; then
    got=match
  else
    got=miss
  fi
  if [ "$got" = "$want" ]; then
    echo "ok   - $label (want=$want)"
  else
    echo "FAIL - $label (want=$want got=$got)"
    failures=$((failures + 1))
  fi
}

expect_opencode_unavailable "usage limit unavailable run" \
  "$fixtures/opencode-unavailable-usage-limit.log" match

expect_opencode_unavailable "zero balance unavailable run" \
  "$fixtures/opencode-unavailable-zero-balance.log" match

expect_opencode_unavailable "normal opencode run" \
  "$fixtures/opencode-no-unavailable.log" miss

expect_opencode_unavailable "reviewed source mentioning provider limits" \
  "$fixtures/opencode-tool-output-provider-wording.log" miss

expect_opencode_unavailable "reviewed guard source containing its own matcher" \
  "$fixtures/opencode-tool-output-guard-source.log" miss

# Synthetic provider rate-limit and quota errors should be detected.
expect_opencode_unavailable "synthetic rate limit" \
  "$fixtures/synthetic-rate-limit.log" match

expect_opencode_unavailable "synthetic credit quota" \
  "$fixtures/synthetic-credit-quota.log" match

usage_message="$(opencode_unavailable_message "$fixtures/opencode-unavailable-usage-limit.log")"
case "$usage_message" in
  *"5-hour usage limit reached"*"[link omitted]"*)
    echo "ok   - provider detail is preserved with links redacted"
    ;;
  *)
    echo "FAIL - provider detail was not safely preserved: $usage_message"
    failures=$((failures + 1))
    ;;
esac

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all guard tests passed"
