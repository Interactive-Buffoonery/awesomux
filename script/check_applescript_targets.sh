#!/usr/bin/env bash
# Smoke scripts drive a dev build while the user's own awesoMux is often running
# under the same process name. System Events resolves `process "awesoMux"` and
# any stored UI element reference by that name, so either can act on the wrong
# app. Address the launched app as `first process whose unix id is $PID` and
# query elements inline, by index, inside that tell.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

by_name='process[[:space:]]+"'
by_ref_loop='repeat[[:space:]]+with[[:space:]]+[[:alnum:]_]+[[:space:]]+in[[:space:]]'
stored_ref='set[[:space:]]+[[:alnum:]_]+[[:space:]]+to[[:space:]]+(a[[:space:]]+reference[[:space:]]+to[[:space:]]+|first[[:space:]]+|last[[:space:]]+|every[[:space:]]+)?(UI[[:space:]]+element|button|window|group|menu[[:space:]]+item|menu[[:space:]]+bar|menu|text[[:space:]]+field|text[[:space:]]+area|static[[:space:]]+text|checkbox|radio[[:space:]]+button|pop[[:space:]]+up[[:space:]]+button|row|sheet|scroll[[:space:]]+area|toolbar|splitter)s?([[:space:]]|$)'
pattern="$by_name|$by_ref_loop|$stored_ref"

if ! command -v rg >/dev/null 2>&1; then
    echo "check_applescript_targets: ripgrep (rg) is required" >&2
    exit 1
fi

unsafe_stored_ref=$'osascript -e \'tell application "System Events"\n    tell first process whose unix id is appPID\n        set targetButton to a reference\n            to button 1 of window 1\n    end tell\nend tell\''
unsafe_ref_loop=$'osascript -e \'tell application "System Events"\n    tell first process whose unix id is appPID\n        repeat with\n            candidateButton in buttons of window 1\n        end repeat\n    end tell\nend tell\''
valid_pid_query=$'osascript -e \'tell application "System Events"\n    tell first process whose unix id is appPID\n        click button 1 of window 1\n    end tell\nend tell\''

if ! rg -qU -e "$pattern" - <<<"$unsafe_stored_ref"; then
    echo "check_applescript_targets: multiline stored-reference self-check failed" >&2
    exit 1
fi
if ! rg -qU -e "$pattern" - <<<"$unsafe_ref_loop"; then
    echo "check_applescript_targets: multiline reference-loop self-check failed" >&2
    exit 1
fi
if rg -qU -e "$pattern" - <<<"$valid_pid_query"; then
    echo "check_applescript_targets: valid PID-targeted query self-check failed" >&2
    exit 1
fi

status=0
if files="$(rg -l --glob '*.sh' -e 'System Events' script)"; then
    scan_status=0
else
    scan_status=$?
fi
if ((scan_status > 1)); then
    echo "check_applescript_targets: failed to find shell scripts to scan" >&2
    exit "$scan_status"
fi

while IFS= read -r file; do
    [[ -z "$file" || "$file" == "script/check_applescript_targets.sh" ]] && continue
    if matches="$(rg -nU -e "$pattern" "$file")"; then
        scan_status=0
    else
        scan_status=$?
    fi
    if ((scan_status > 1)); then
        echo "check_applescript_targets: failed to scan $file" >&2
        exit "$scan_status"
    fi
    if ((scan_status == 0)); then
        printf '%s\n' "$matches"
        echo "error: $file: target System Events by unix id and query UI elements inline; see this script's header" >&2
        status=1
    fi
done <<<"$files"
exit "$status"
