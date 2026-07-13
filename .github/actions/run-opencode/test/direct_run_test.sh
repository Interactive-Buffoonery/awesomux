#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
action_dir="$(cd "$test_dir/.." && pwd)"
temp_dir="$(mktemp -d)"
trap 'trash "$temp_dir" 2>/dev/null || true' EXIT

mkdir -p "$temp_dir/bin" "$temp_dir/runner"

cat > "$temp_dir/bin/opencode" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$OPENCODE_ARGS_CAPTURE"
count=0
if [ -f "$OPENCODE_CALL_COUNT" ]; then count="$(cat "$OPENCODE_CALL_COUNT")"; fi
count=$((count + 1))
printf '%s\n' "$count" > "$OPENCODE_CALL_COUNT"
case "$OPENCODE_FIXTURE_MODE" in
  success|production_diff|deduplicate)
    if [ "$OPENCODE_FIXTURE_MODE" = "production_diff" ]; then
      git diff "$BASE_RANGE" -- > "$PRODUCTION_DIFF_CAPTURE"
    fi
    printf '%s\n' \
      '{"type":"text","part":{"text":"Inspecting the supplied range."}}' \
      '{"type":"text","part":{"text":"## Code Review\n\nNo blocking or should-fix findings."}}'
    ;;
  narration)
    printf '%s\n' '{"type":"text","part":{"text":"I inspected the diff."}}'
    ;;
  narration_then_continue)
    if printf '%s\n' "$@" | grep -qx -- '--continue'; then
      printf '%s\n' '{"type":"text","part":{"text":"## Code Review\n\nNo blocking or should-fix findings."}}'
    else
      printf '%s\n' '{"type":"text","part":{"text":"I inspected the diff."}}'
    fi
    ;;
  verbose_no_findings)
    printf '%s\n' '{"type":"text","part":{"text":"## Code Review\n\nNo blocking or should-fix findings.\n\nEverything is excellent."}}'
    ;;
  malformed)
    printf '%s\n' 'not-json' '{"type":"tool_use","part":{}}'
    ;;
esac
EOF

cat > "$temp_dir/bin/git" <<'EOF'
#!/usr/bin/env bash
if [ "${OVERSIZED_DIFF:-false}" = "true" ] && [ "${1:-}" = "diff" ]; then
  head -c 300000 /dev/zero | tr '\0' x
  exit 0
fi
if [ "${PRODUCTION_DIFF:-false}" = "true" ] && [ "${1:-}" = "diff" ]; then
  awk 'BEGIN {
    for (file = 1; file <= 12; file++) {
      printf "diff --git a/Sources/Fixture%02d.swift b/Sources/Fixture%02d.swift\n", file, file
      printf "--- a/Sources/Fixture%02d.swift\n", file
      printf "+++ b/Sources/Fixture%02d.swift\n", file
      printf "@@ -1,30 +1,30 @@\n"
      for (line = 1; line <= 30; line++) printf "+let fixture%02dLine%02d = %d\n", file, line, line
    }
  }'
  exit 0
fi
exec /usr/bin/git "$@"
EOF

cat > "$temp_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
if printf '%s\n' "$@" | grep -qx -- '--paginate'; then
  if [ -n "${GH_EXISTING_COMMENT_IDS:-}" ]; then
    printf '%s\n' "$GH_EXISTING_COMMENT_IDS"
  fi
  exit 0
fi
{
  echo '---'
  printf '%s\n' "$@"
} >> "$GH_ARGS_CAPTURE"
input_path=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = '--input' ]; then
    input_path="$2"
    break
  fi
  shift
done
if [ -n "$input_path" ]; then
  cp "$input_path" "$GH_BODY_CAPTURE"
fi
EOF

chmod +x "$temp_dir/bin/opencode" "$temp_dir/bin/gh" "$temp_dir/bin/git"

run_wrapper() {
  local mode="$1"

  PATH="$temp_dir/bin:$PATH" \
    RUNNER_TEMP="$temp_dir/runner" \
    GITHUB_RUN_ID="direct-run-$mode" \
    GITHUB_REPOSITORY="Interactive-Buffoonery/awesomux" \
    ISSUE_NUMBER="574" \
    MODEL="synthetic/hf:zai-org/GLM-5.2" \
    AGENT="review" \
    PROMPT="Review the exact passive range." \
    REVIEW_GUARD="true" \
    OPENCODE_FIXTURE_MODE="$mode" \
    OPENCODE_CALL_COUNT="$temp_dir/opencode-count-$mode" \
    OPENCODE_ARGS_CAPTURE="$temp_dir/opencode-args-$mode" \
    GH_ARGS_CAPTURE="$temp_dir/gh-args-$mode" \
    GH_BODY_CAPTURE="$temp_dir/gh-body-$mode" \
    GH_EXISTING_COMMENT_IDS="${GH_EXISTING_COMMENT_IDS:-}" \
    GITHUB_STEP_SUMMARY="$temp_dir/summary-$mode" \
    GITHUB_OUTPUT="$temp_dir/output-$mode" \
    BASE_RANGE="${BASE_RANGE_OVERRIDE:-}" \
    LARGE_DIFF_MODE="${LARGE_DIFF_MODE_OVERRIDE:-fail}" \
    OVERSIZED_DIFF="${OVERSIZED_DIFF:-false}" \
    PRODUCTION_DIFF="${PRODUCTION_DIFF:-false}" \
    PRODUCTION_DIFF_CAPTURE="$temp_dir/production-diff-$mode" \
    bash "$action_dir/run-opencode.sh"
}

run_wrapper success

grep -Fx -- "run" "$temp_dir/opencode-args-success"
grep -Fx -- "--pure" "$temp_dir/opencode-args-success"
grep -Fx -- "--format" "$temp_dir/opencode-args-success"
grep -Fx -- "json" "$temp_dir/opencode-args-success"
grep -Fx -- "synthetic/hf:zai-org/GLM-5.2" "$temp_dir/opencode-args-success"
if grep -Fx -- "github" "$temp_dir/opencode-args-success"; then
  echo "OpenCode GitHub wrapper must not run" >&2
  exit 1
fi

grep -Fx -- "repos/Interactive-Buffoonery/awesomux/issues/574/comments" \
  "$temp_dir/gh-args-success"
jq -e '.body == "<!-- awesomux-opencode-review -->\n## Code Review\n\nNo blocking or should-fix findings.\n"' \
  "$temp_dir/gh-body-success" >/dev/null

GH_EXISTING_COMMENT_IDS=$'101\n202'
export GH_EXISTING_COMMENT_IDS
run_wrapper deduplicate
unset GH_EXISTING_COMMENT_IDS
grep -Fx -- "repos/Interactive-Buffoonery/awesomux/issues/comments/101" \
  "$temp_dir/gh-args-deduplicate"
grep -Fx -- "repos/Interactive-Buffoonery/awesomux/issues/comments/202" \
  "$temp_dir/gh-args-deduplicate"
grep -Fx -- "PATCH" "$temp_dir/gh-args-deduplicate"
grep -Fx -- "DELETE" "$temp_dir/gh-args-deduplicate"
jq -e '.body | startswith("<!-- awesomux-opencode-review -->\n## Code Review")' \
  "$temp_dir/gh-body-deduplicate" >/dev/null

run_wrapper narration_then_continue
grep -Fx -- "--continue" "$temp_dir/opencode-args-narration_then_continue"
test "$(cat "$temp_dir/opencode-count-narration_then_continue")" -eq 2
grep -Fq "| continuation |" "$temp_dir/summary-narration_then_continue"

BASE_RANGE_OVERRIDE="base...head" OVERSIZED_DIFF=true
export BASE_RANGE_OVERRIDE OVERSIZED_DIFF
set +e
run_wrapper oversized
oversized_status=$?
set -e
unset BASE_RANGE_OVERRIDE OVERSIZED_DIFF
test "$oversized_status" -ne 0
test ! -e "$temp_dir/opencode-count-oversized"
grep -Fq "diff exceeds the bounded review preview" "$temp_dir/summary-oversized"

BASE_RANGE_OVERRIDE="base...head" OVERSIZED_DIFF=true LARGE_DIFF_MODE_OVERRIDE="skip"
export BASE_RANGE_OVERRIDE OVERSIZED_DIFF LARGE_DIFF_MODE_OVERRIDE
run_wrapper oversized_skip
unset BASE_RANGE_OVERRIDE OVERSIZED_DIFF LARGE_DIFF_MODE_OVERRIDE
test ! -e "$temp_dir/opencode-count-oversized_skip"
grep -Fq "OpenCode automatic review skipped" "$temp_dir/summary-oversized_skip"
grep -Fq "diff_too_large=true" "$temp_dir/output-oversized_skip"

BASE_RANGE_OVERRIDE="base...head" PRODUCTION_DIFF=true
export BASE_RANGE_OVERRIDE PRODUCTION_DIFF
run_wrapper production_diff
unset BASE_RANGE_OVERRIDE PRODUCTION_DIFF
test "$(cat "$temp_dir/opencode-count-production_diff")" -eq 1
grep -Fq "408 lines" "$temp_dir/summary-production_diff"
test "$(grep -c '^diff --git ' "$temp_dir/production-diff-production_diff")" -eq 12
production_lines="$(wc -l < "$temp_dir/production-diff-production_diff" | tr -d ' ')"
test "$production_lines" -ge 350
test "$production_lines" -le 500

for mode in narration malformed verbose_no_findings; do
  set +e
  run_wrapper "$mode"
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    echo "$mode output must fail the review guard" >&2
    exit 1
  fi
  if [ -e "$temp_dir/gh-body-$mode" ]; then
    echo "$mode output must never be published" >&2
    exit 1
  fi
done

echo "direct opencode run test passed"
