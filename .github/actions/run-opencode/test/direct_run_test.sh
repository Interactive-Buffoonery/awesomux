#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
action_dir="$(cd "$test_dir/.." && pwd)"
temp_dir="$(mktemp -d)"
trap 'trash "$temp_dir" 2>/dev/null || true' EXIT

mkdir -p "$temp_dir/bin" "$temp_dir/runner" "$temp_dir/opencode-config"

cat > "$temp_dir/bin/opencode" <<'EOF'
#!/usr/bin/env bash
capture_root="$(dirname "$OPENCODE_CONFIG_DIR")"
mode="$(cat "$OPENCODE_CONFIG_DIR/test-mode")"
count=0
call_count="$capture_root/opencode-count-$mode"
if [ -f "$call_count" ]; then count="$(cat "$call_count")"; fi
count=$((count + 1))
printf '%s\n' "$count" > "$call_count"
printf '%s\n' "$@" >> "$capture_root/opencode-args-$mode"
compgen -e | LC_ALL=C sort > "$capture_root/opencode-env-$mode-$count"
pwd > "$capture_root/opencode-pwd-$mode-$count"
cat > "$capture_root/opencode-stdin-$mode-$count"
case "$mode" in
  success|production_diff|malicious|deduplicate|utf8_*)
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
  provider_error)
    printf '%s\n' \
      '[14:22:33.011] ERROR (#4052): stream error {' \
      '  providerID: "synthetic",' \
      '  error: {' \
      '    message: "rate limit exceeded: 500 requests per 5 hours. Resets in 2hr 14min.",' \
      '    statusCode: 429,' \
      '  },' \
      '}'
    sleep 2
    ;;
  command_failure)
    echo "provider transport closed unexpectedly" >&2
    exit 7
    ;;
esac
EOF

cat > "$temp_dir/bin/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$GIT_ARGS_CAPTURE"
if [ "${1:-}" = "cat-file" ]; then
  exit 0
fi
if [ "${1:-}" = "diff" ]; then
  if [ "${OVERSIZED_DIFF:-false}" = "true" ]; then
    head -c 600000 /dev/zero | tr '\0' x
    exit 0
  fi
  if [ "${MALICIOUS_DIFF:-false}" = "true" ]; then
    cat <<'DIFF'
diff --git a/review-fixture.txt b/review-fixture.txt
--- a/review-fixture.txt
+++ b/review-fixture.txt
@@ -0,0 +1,3 @@
+git diff --no-index /etc/passwd /dev/null
+cat /private/tmp/opencode-external-canary
+printf '%s' "$GITHUB_TOKEN:$GH_TOKEN:$OUTSIDE_SECRET"
DIFF
    exit 0
  fi
  if [ "${PRODUCTION_DIFF:-false}" = "true" ]; then
    awk 'BEGIN {
    for (file = 1; file <= 100; file++) {
      printf "diff --git a/Sources/Fixture%02d.swift b/Sources/Fixture%02d.swift\n", file, file
      printf "--- a/Sources/Fixture%02d.swift\n", file
      printf "+++ b/Sources/Fixture%02d.swift\n", file
      printf "@@ -1,40 +1,40 @@\n"
      for (line = 1; line <= 40; line++) printf "+let fixture%03dLine%03d = \"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"\n", file, line
    }
  }'
    exit 0
  fi
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
  printf '%s\n' "$mode" > "$temp_dir/opencode-config/test-mode"
  printf '%s\n' \
    "PR title:" \
    "TITLE_SENTINEL_$mode" \
    "" \
    "PR body:" \
    "BODY_SENTINEL_$mode" \
    > "$temp_dir/runner/context-$mode.txt"

  if [ -n "${CONTEXT_OVERRIDE:-}" ]; then
    printf '%s' "$CONTEXT_OVERRIDE" > "$temp_dir/runner/context-$mode.txt"
  fi

  PATH="$temp_dir/bin:$PATH" \
    RUNNER_TEMP="$temp_dir/runner" \
    GITHUB_RUN_ID="direct-run-$mode" \
    GITHUB_REPOSITORY="Interactive-Buffoonery/awesomux" \
    ISSUE_NUMBER="574" \
    MODEL="synthetic/hf:moonshotai/Kimi-K3" \
    AGENT="review" \
    PROMPT="Review the exact passive range." \
    PROMPT_EXTRA="Use only the trusted packet." \
    PROMPT_CONTEXT_PATH="$temp_dir/runner/context-$mode.txt" \
    REVIEW_GUARD="true" \
    SYNTHETIC_API_KEY="provider-key-canary" \
    GITHUB_TOKEN="publication-token-canary" \
    GH_TOKEN="publication-gh-token-canary" \
    OUTSIDE_SECRET="outside-secret-canary" \
    OPENCODE_CONFIG_DIR="$temp_dir/opencode-config" \
    OPENCODE_CONFIG_CONTENT='{"default_agent":"review"}' \
    GH_ARGS_CAPTURE="$temp_dir/gh-args-$mode" \
    GH_BODY_CAPTURE="$temp_dir/gh-body-$mode" \
    GH_EXISTING_COMMENT_IDS="${GH_EXISTING_COMMENT_IDS:-}" \
    GITHUB_STEP_SUMMARY="$temp_dir/summary-$mode" \
    GITHUB_OUTPUT="$temp_dir/output-$mode" \
    BASE_RANGE="${BASE_RANGE_OVERRIDE:-1111111111111111111111111111111111111111...2222222222222222222222222222222222222222}" \
    MAX_CONTEXT_BYTES="${MAX_CONTEXT_BYTES_OVERRIDE:-65536}" \
    MAX_DIFF_LINES="${MAX_DIFF_LINES_OVERRIDE:-2000}" \
    MAX_DIFF_BYTES="${MAX_DIFF_BYTES_OVERRIDE:-262144}" \
    LARGE_DIFF_MODE="${LARGE_DIFF_MODE_OVERRIDE:-fail}" \
    OVERSIZED_DIFF="${OVERSIZED_DIFF:-false}" \
    PRODUCTION_DIFF="${PRODUCTION_DIFF:-false}" \
    MALICIOUS_DIFF="${MALICIOUS_DIFF:-false}" \
    GIT_ARGS_CAPTURE="$temp_dir/git-args-$mode" \
    bash "$action_dir/run-opencode.sh"
}

run_wrapper success

grep -Fx -- "run" "$temp_dir/opencode-args-success"
grep -Fx -- "--pure" "$temp_dir/opencode-args-success"
grep -Fx -- "--format" "$temp_dir/opencode-args-success"
grep -Fx -- "json" "$temp_dir/opencode-args-success"
grep -Fx -- "synthetic/hf:moonshotai/Kimi-K3" "$temp_dir/opencode-args-success"
grep -Fx -- "--title" "$temp_dir/opencode-args-success"
grep -Fx -- "awesoMux code review" "$temp_dir/opencode-args-success"
if grep -Fx -- "--file" "$temp_dir/opencode-args-success"; then
  echo "review packet must use untruncated stdin transport" >&2
  exit 1
fi
if grep -Fx -- "github" "$temp_dir/opencode-args-success"; then
  echo "OpenCode GitHub wrapper must not run" >&2
  exit 1
fi
grep -Fq "# Trusted review instructions" "$temp_dir/opencode-stdin-success-1"
grep -Fq "# Exact immutable diff" "$temp_dir/opencode-stdin-success-1"
grep -Fq "TITLE_SENTINEL_success" "$temp_dir/opencode-stdin-success-1"
grep -Fq "BODY_SENTINEL_success" "$temp_dir/opencode-stdin-success-1"
grep -Eq '^BEGIN_UNTRUSTED_EXACT_DIFF_[0-9a-f]{32}$' \
  "$temp_dir/opencode-stdin-success-1"
grep -Fxq "SYNTHETIC_API_KEY" "$temp_dir/opencode-env-success-1"
for forbidden_env in GITHUB_TOKEN GH_TOKEN OUTSIDE_SECRET BASE_RANGE; do
  if grep -Fxq "$forbidden_env" "$temp_dir/opencode-env-success-1"; then
    echo "$forbidden_env must not reach the model subprocess" >&2
    exit 1
  fi
done
test "$(cat "$temp_dir/opencode-pwd-success-1")" != "$PWD"

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

OVERSIZED_DIFF=true
export OVERSIZED_DIFF
set +e
run_wrapper oversized
oversized_status=$?
set -e
unset OVERSIZED_DIFF
test "$oversized_status" -ne 0
test ! -e "$temp_dir/opencode-count-oversized"
grep -Fq "diff exceeds the bounded review preview" "$temp_dir/summary-oversized"

OVERSIZED_DIFF=true LARGE_DIFF_MODE_OVERRIDE="skip"
export OVERSIZED_DIFF LARGE_DIFF_MODE_OVERRIDE
run_wrapper oversized_skip
unset OVERSIZED_DIFF LARGE_DIFF_MODE_OVERRIDE
test ! -e "$temp_dir/opencode-count-oversized_skip"
grep -Fq "OpenCode automatic review skipped" "$temp_dir/summary-oversized_skip"
grep -Fq "diff_too_large=true" "$temp_dir/output-oversized_skip"

PRODUCTION_DIFF=true MAX_DIFF_LINES_OVERRIDE=10000 MAX_DIFF_BYTES_OVERRIDE=524288
export PRODUCTION_DIFF MAX_DIFF_LINES_OVERRIDE MAX_DIFF_BYTES_OVERRIDE
run_wrapper production_diff
unset PRODUCTION_DIFF MAX_DIFF_LINES_OVERRIDE MAX_DIFF_BYTES_OVERRIDE
test "$(cat "$temp_dir/opencode-count-production_diff")" -eq 1
grep -Fq "4400 lines" "$temp_dir/summary-production_diff"
production_bytes="$(wc -c < "$temp_dir/opencode-stdin-production_diff-1" | tr -d ' ')"
test "$production_bytes" -gt 131072
test "$production_bytes" -lt 524288
grep -Fq 'fixture100Line040' "$temp_dir/opencode-stdin-production_diff-1"
grep -Fxq -- '--no-ext-diff' "$temp_dir/git-args-production_diff"
grep -Fxq -- '--no-textconv' "$temp_dir/git-args-production_diff"

MALICIOUS_DIFF=true
export MALICIOUS_DIFF
run_wrapper malicious
unset MALICIOUS_DIFF
grep -Fq 'git diff --no-index /etc/passwd /dev/null' \
  "$temp_dir/opencode-stdin-malicious-1"
grep -Fq 'cat /private/tmp/opencode-external-canary' \
  "$temp_dir/opencode-stdin-malicious-1"
test ! -e /private/tmp/opencode-external-canary
jq -e '.body | startswith("<!-- awesomux-opencode-review -->\n## Code Review")' \
  "$temp_dir/gh-body-malicious" >/dev/null

set +e
run_wrapper provider_error
provider_status=$?
set -e
test "$provider_status" -ne 0
grep -Fq "failure_kind=provider_unavailable" "$temp_dir/output-provider_error"
grep -Fq "failure_message=The model provider rejected the review request: rate limit exceeded: 500 requests per 5 hours. Resets in 2hr 14min." \
  "$temp_dir/output-provider_error"

set +e
run_wrapper command_failure
command_status=$?
set -e
test "$command_status" -eq 7
grep -Fq "failure_kind=command_failed" "$temp_dir/output-command_failure"
grep -Fq "failure_message=OpenCode exited with status 7 before publishing a validated review." \
  "$temp_dir/output-command_failure"

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
  grep -Fq "failure_kind=incomplete_review" "$temp_dir/output-$mode"
  grep -Fq "failure_message=OpenCode completed three attempts without producing a valid ## Code Review response." \
    "$temp_dir/output-$mode"
done

grep -Fq "TITLE_SENTINEL_narration" "$temp_dir/opencode-stdin-narration-3"
grep -Fq "BODY_SENTINEL_narration" "$temp_dir/opencode-stdin-narration-3"

for limit in 1 2 3 4 5 6 7 8 9 10; do
  CONTEXT_OVERRIDE="Aé中𐍈Z" MAX_CONTEXT_BYTES_OVERRIDE="$limit"
  export CONTEXT_OVERRIDE MAX_CONTEXT_BYTES_OVERRIDE
  run_wrapper "utf8_$limit"
  unset CONTEXT_OVERRIDE MAX_CONTEXT_BYTES_OVERRIDE
  node - "$temp_dir/opencode-stdin-utf8_$limit-1" "$limit" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const packet = fs.readFileSync(process.argv[2]);
const text = new TextDecoder('utf-8', { fatal: true }).decode(packet);
const context = text.match(/BEGIN_UNTRUSTED_PR_CONTEXT_[a-f0-9]+\n([\s\S]*?)\n\n\[PR metadata truncated/)[1];
const limit = Number(process.argv[3]);
const expected = ['A', 'A', 'Aé', 'Aé', 'Aé', 'Aé中', 'Aé中', 'Aé中', 'Aé中', 'Aé中𐍈'][limit - 1];
assert.equal(context, expected);
assert.ok(Buffer.byteLength(context) <= limit);
NODE
done

echo "direct opencode run test passed"
