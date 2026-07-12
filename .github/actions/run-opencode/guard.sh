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

opencode_unavailable_detected() {
  awk '
    / ERROR .*stream error/ { in_provider_error = 1 }
    in_provider_error { print }
    in_provider_error && /^}/ { in_provider_error = 0 }
    /"type"[[:space:]]*:[[:space:]]*"error"/ { print }
  ' "$1" | grep -Eiq "$opencode_unavailable_pattern"
}
