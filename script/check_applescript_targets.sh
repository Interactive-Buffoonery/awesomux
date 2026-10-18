#!/usr/bin/env bash
# Smoke scripts drive a dev build while the user's own awesoMux is often running
# under the same process name. System Events resolves `process "awesoMux"` and
# any stored UI element reference by that name, so either can act on the wrong
# app. Address the launched app as `first process whose unix id is $PID` and
# query elements inline, by index, inside that tell.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

by_name='process "'
by_ref_loop='repeat with [[:alnum:]_]+ in '
stored_ref='set [[:alnum:]_]+ to (a reference to |first |last |every )?(UI element|button|window|group|menu item|menu bar|menu|text field|text area|static text|checkbox|radio button|pop up button|row|sheet|scroll area|toolbar|splitter)( |s |$)'

status=0
while IFS= read -r file; do
    if grep -nE "$by_name|$by_ref_loop|$stored_ref" "$file"; then
        echo "error: $file: target System Events by unix id and query UI elements inline; see this script's header" >&2
        status=1
    fi
done < <(grep -rlE 'System Events' script --include='*.sh' | grep -v '^script/check_applescript_targets\.sh$')
exit "$status"
