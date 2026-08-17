#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 4 ]]; then
    echo "usage: $0 <repository> <name> <color> <description>" >&2
    exit 2
fi

repository="$1"
name="$2"
color="$3"
description="$4"
encoded_name="$(jq -rn --arg value "$name" '$value | @uri')"
endpoint="repos/${repository}/labels/${encoded_name}"

temp_dir="$(mktemp -d)"
response_file="${temp_dir}/response"
error_file="${temp_dir}/error"

cleanup() {
    [[ ! -e "$response_file" ]] || unlink "$response_file"
    [[ ! -e "$error_file" ]] || unlink "$error_file"
    rmdir "$temp_dir"
}
trap cleanup EXIT

if gh api "$endpoint" >"$response_file" 2>"$error_file"; then
    current_color="$(jq -r '.color' <"$response_file")"
    current_description="$(jq -r '.description // ""' <"$response_file")"

    if [[ -s "$error_file" ]]; then
        cat "$error_file" >&2
    fi

    if [[ "$current_color" != "$color" || "$current_description" != "$description" ]]; then
        gh api \
            --method PATCH \
            "$endpoint" \
            -f color="$color" \
            -f description="$description" \
            >/dev/null
    fi
elif grep -Fq "HTTP 404" "$error_file"; then
    gh api \
        --method POST \
        "repos/${repository}/labels" \
        -f name="$name" \
        -f color="$color" \
        -f description="$description" \
        >/dev/null
else
    cat "$error_file" >&2
    exit 1
fi
