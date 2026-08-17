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
body_file="${temp_dir}/body"

cleanup() {
    [[ ! -e "$response_file" ]] || unlink "$response_file"
    [[ ! -e "$error_file" ]] || unlink "$error_file"
    [[ ! -e "$body_file" ]] || unlink "$body_file"
    rmdir "$temp_dir"
}
trap cleanup EXIT

lookup_exit=0
gh api --include "$endpoint" >"$response_file" 2>"$error_file" || lookup_exit="$?"
http_status="$(awk 'NR == 1 { print $2 }' "$response_file")"

if [[ "$lookup_exit" -eq 0 && "$http_status" == 2?? ]]; then
    awk 'body { print } /^[[:space:]]*$/ { body = 1 }' "$response_file" >"$body_file"
    current_color="$(jq -r '.color' <"$body_file")"
    current_description="$(jq -r '.description // ""' <"$body_file")"

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
elif [[ "$http_status" == "404" ]]; then
    gh api \
        --method POST \
        "repos/${repository}/labels" \
        -f name="$name" \
        -f color="$color" \
        -f description="$description" \
        >/dev/null
else
    cat "$error_file" >&2
    if [[ -n "$http_status" ]]; then
        echo "label lookup failed with HTTP ${http_status}" >&2
    fi
    exit 1
fi
