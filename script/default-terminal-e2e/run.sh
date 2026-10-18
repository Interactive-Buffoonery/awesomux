#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/awesomux-default-terminal-e2e.XXXXXX")"
swiftc -swift-version 6 -module-cache-path "$OUTPUT/module-cache" \
  "$ROOT/Sources/awesoMux/Services/DefaultTerminalSettingsModel.swift" \
  "$ROOT/Sources/awesoMux/Services/TerminalFileOpenRequest.swift" \
  "$ROOT/script/default-terminal-e2e/main.swift" -o "$OUTPUT/check"
"$OUTPUT/check" | tee "$OUTPUT/report.txt"
python3 - "$ROOT" <<'PY' | tee -a "$OUTPUT/report.txt"
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
source = (root / 'script/build_and_run.sh').read_text()
plist = source.split('cat >"$INFO_PLIST" <<PLIST\n', 1)[1].split('\nPLIST', 1)[0]
values = plistlib.loads(plist.encode())
types = {t for d in values['CFBundleDocumentTypes'] for t in d['LSItemContentTypes']}
assert types == {'public.unix-executable', 'com.apple.terminal.shell-script'}
assert values['UTImportedTypeDeclarations'][0]['UTTypeTagSpecification']['public.filename-extension'] == ['command', 'tool']
assert all(d['CFBundleTypeRole'] == 'Shell' for d in values['CFBundleDocumentTypes'])
print('PASS: staged bundle declares exactly the supported terminal document types.')
PY
printf 'Report: %s/report.txt\n' "$OUTPUT"
