#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/actions/run-opencode/guard.sh
# shellcheck disable=SC1091
. "$script_dir/guard.sh"

opencode_log="${RUNNER_TEMP:-/tmp}/opencode-run-${GITHUB_RUN_ID:-$$}.log"
telemetry_file="${opencode_log}.telemetry"
final_outcome="failed"
diff_lines="unknown"
diff_bytes="unknown"
: > "$telemetry_file"

write_telemetry_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return
  {
    echo "### OpenCode review telemetry"
    echo
    echo "- Model: \`${MODEL}\`"
    echo "- Diff preview: ${diff_lines} lines, ${diff_bytes} bytes"
    echo "- Final outcome: ${final_outcome}"
    echo
    echo "| Attempt | Mode | Duration | Input tokens | Output tokens | Total tokens | Tool output truncated | Outcome |"
    echo "| ---: | --- | ---: | ---: | ---: | ---: | --- | --- |"
    cat "$telemetry_file"
  } >> "$GITHUB_STEP_SUMMARY"
}
trap write_telemetry_summary EXIT

if [ -n "${BASE_RANGE:-}" ]; then
  diff_probe="${opencode_log}.diff"
  git diff "$BASE_RANGE" -- > "$diff_probe"
  diff_lines="$(wc -l < "$diff_probe" | tr -d ' ')"
  diff_bytes="$(wc -c < "$diff_probe" | tr -d ' ')"
  if [ "$diff_lines" -gt "${MAX_DIFF_LINES:-2000}" ] || [ "$diff_bytes" -gt "${MAX_DIFF_BYTES:-262144}" ]; then
    final_outcome="diff too large"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      {
        echo "### OpenCode review requires human review"
        echo
        echo "The exact diff exceeds the bounded review preview (${diff_lines} lines, ${diff_bytes} bytes)."
      } >> "$GITHUB_STEP_SUMMARY"
    fi
    echo "::error title=OpenCode diff too large::The exact diff exceeds the bounded review preview (${diff_lines} lines, ${diff_bytes} bytes); human review is required." >&2
    exit 1
  fi
fi

set_opencode_unavailable_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "opencode_unavailable=$1" >> "$GITHUB_OUTPUT"
  fi
}

set_opencode_unavailable_output false

report_opencode_unavailable() {
  local message="OpenCode reported a usage, billing, quota, or zero-balance limit. Stopping now and failing the review job."

  echo "::notice title=OpenCode unavailable::$message" >&2
  set_opencode_unavailable_output true

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### OpenCode review skipped"
      echo
      echo "OpenCode reported a usage, billing, quota, or zero-balance limit, so this run stopped early and failed instead of reporting a false-green review."
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

terminate_opencode() {
  local pid="$1"

  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true

  for _ in 1 2 3 4 5; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return
    fi
    sleep 1
  done

  kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
}

record_attempt() {
  local outcome="$1" duration input_tokens output_tokens total_tokens truncated
  duration="$(( $(date +%s) - attempt_started ))s"
  IFS=$'\t' read -r input_tokens output_tokens total_tokens truncated < <(node "$script_dir/summarize-log.mjs" "$attempt_log")
  printf '| %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$attempt" "$mode" "$duration" "$input_tokens" "$output_tokens" "$total_tokens" "$truncated" "$outcome" >> "$telemetry_file"
}

for attempt in 1 2 3; do
  attempt_log="${opencode_log}.attempt-${attempt}"
  : > "$attempt_log"
  review_file="${attempt_log}.review.md"
  attempt_started="$(date +%s)"
  mode="initial"
  attempt_prompt="$PROMPT"
  continue_session=false
  if [ "$attempt" -eq 2 ]; then
    mode="continuation"
    continue_session=true
    attempt_prompt="Stop investigating. Using the diff and context already in this session, output the final public response now. Start with ## Code Review. If there are no material findings, output only the required no-findings sentence."
  elif [ "$attempt" -eq 3 ]; then
    mode="fresh fallback"
  fi

  # Positional parameters intentionally expand inside the child shell.
  # shellcheck disable=SC2016
  if [ "$continue_session" = "true" ]; then
    child_command='opencode --pure run --continue --format json --model "$1" --agent "$2" "$3" 2>&1 | tee -a "$4"'
  else
    # shellcheck disable=SC2016
    child_command='opencode --pure run --format json --model "$1" --agent "$2" "$3" 2>&1 | tee -a "$4"'
  fi
  if command -v setsid >/dev/null 2>&1; then
    setsid bash -o pipefail -c "$child_command" _ "$MODEL" "$AGENT" "$attempt_prompt" "$attempt_log" &
  else
    bash -o pipefail -c "$child_command" _ "$MODEL" "$AGENT" "$attempt_prompt" "$attempt_log" &
  fi
  opencode_pid=$!

  while kill -0 "$opencode_pid" 2>/dev/null; do
    if opencode_unavailable_detected "$attempt_log"; then
      record_attempt "provider unavailable"
      report_opencode_unavailable
      terminate_opencode "$opencode_pid"
      wait "$opencode_pid" 2>/dev/null || true
      exit 1
    fi

    sleep 1
  done

  set +e
  wait "$opencode_pid"
  exit_code=$?
  set -e

  if opencode_unavailable_detected "$attempt_log"; then
    record_attempt "provider unavailable"
    report_opencode_unavailable
    exit 1
  fi

  if [ "$exit_code" -ne 0 ]; then
    record_attempt "command failed ($exit_code)"
    exit "$exit_code"
  fi

  # The review agent must always produce a "## Code Review" heading. Both the
  # automatic review workflow and /codereview comment runs opt into this guard
  # (REVIEW_GUARD=true); bounded recovery first continues the same session so
  # the model can finalize without rereading the diff, then tries one fresh run.
  if [ "${REVIEW_GUARD:-}" = "true" ] && [ "${AGENT:-}" = "review" ] && [ "$exit_code" -eq 0 ]; then
    if ! node "$script_dir/../../scripts/extract-opencode-review.mjs" "$attempt_log" "$review_file"; then
      record_attempt "incomplete"
      if [ "$attempt" -lt 3 ]; then
        echo "::warning title=OpenCode review incomplete::Attempt $attempt/3 ($mode) ended without a ## Code Review. Continuing with bounded recovery..." >&2
        continue
      fi
      echo "::error title=OpenCode review incomplete::No '## Code Review' after initial, continuation, and fresh fallback attempts; failing instead of accepting an empty review." >&2
      exit 1
    fi

    record_attempt "success"
    cp "$attempt_log" "$opencode_log"

    # Preserve the log shape consumed by the inline-review parser while keeping
    # the model invocation independent from OpenCode's checkout-capable GitHub
    # wrapper.
    {
      echo '[00:00:00] INFO (#0): llm runtime selected'
      cat "$review_file"
      echo 'Checking if branch is dirty...'
    } >> "$opencode_log"

    review_marker='<!-- awesomux-opencode-review -->'
    review_payload="$RUNNER_TEMP/opencode-review-payload.json"
    jq -n --arg marker "$review_marker" --rawfile body "$review_file" \
      '{body: ($marker + "\n" + $body)}' > "$review_payload"
    mapfile -t review_comment_ids < <(gh api --paginate \
      "repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/comments" \
      --jq '.[] | select(
        .user.login == "github-actions[bot]" and
        (.body | startswith("<!-- awesomux-opencode-review -->") or
          startswith("## Code Review"))
      ) | .id')
    if [ "${#review_comment_ids[@]}" -gt 0 ]; then
      gh api --method PATCH \
        "repos/${GITHUB_REPOSITORY}/issues/comments/${review_comment_ids[0]}" \
        --input "$review_payload" >/dev/null
      for duplicate_id in "${review_comment_ids[@]:1}"; do
        gh api --method DELETE \
          "repos/${GITHUB_REPOSITORY}/issues/comments/${duplicate_id}" >/dev/null
      done
    else
      gh api --method POST \
        "repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/comments" \
        --input "$review_payload" >/dev/null
    fi
    final_outcome="review published"
  fi

  exit "$exit_code"
done
