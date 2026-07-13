#!/usr/bin/env bash
# Shared review-output guard helpers for run-opencode.sh.
#
# Sourced by run-opencode.sh and by the unit test so both exercise identical
# detection logic. This file defines functions only; it runs nothing on source.
#
# OpenCode currently marks some usage, billing, quota, and zero-balance failures
# retryable, so the CLI can keep running until the workflow timeout even after
# the provider has refused the request.
opencode_unavailable_pattern="GoUsageLimitError|5[- ]hour usage limit reached|limitName[[:space:]]*['\":={, ]*5[- ]hour|enable usage from your available balance|insufficient (credit|balance|quota)|zero[ -]?balance|balance[[:space:]]*(is|=)[[:space:]]*0|billing (limit|quota|usage)|payment required|PaymentRequired|rate[[:space:]]*limit[[:space:]]*(exceeded|reached)|quota[[:space:]]*exceeded|subscription[[:space:]]*(limit|quota|expired|inactive)|Too Many Requests"

opencode_provider_error_block() {
  awk '
    /^\[[^]]+\] ERROR \(#[0-9]+\): stream error \{$/ { in_provider_error = 1 }
    in_provider_error { print }
    in_provider_error && /^}/ { in_provider_error = 0 }
  ' "$1"
}

opencode_unavailable_detected() {
  opencode_provider_error_block "$1" | grep -Eiq "$opencode_unavailable_pattern"
}

opencode_unavailable_message() {
  local message
  message="$(opencode_provider_error_block "$1" | sed -n 's/^[[:space:]]*message: "\(.*\)",$/\1/p' | head -n 1)"
  if [ -z "$message" ]; then
    message="The model provider rejected the review request because of an account or rate limit."
  fi
  printf '%s' "$message" \
    | sed -E "s#https?://[^[:space:]\"]+#[link omitted]#g; s/wrk_[[:alnum:]_-]+/[workspace]/g" \
    | cut -c 1-300
}
