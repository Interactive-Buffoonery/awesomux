#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
if [[ "$#" -gt 1 || ( "$MODE" != run && "$MODE" != --check-prerequisites ) ]]; then
    echo "Usage: script/native-ui.sh [--check-prerequisites]" >&2
    exit 64
fi
mkdir -p .build/minimighty-ui
OUTPUT="$(mktemp -d "$ROOT_DIR/.build/minimighty-ui/run.XXXXXXXX")"
printf 'Native UI evidence: %s\n' "$OUTPUT"
swiftc script/terminal-lifecycle-e2e/native.swift -o "$OUTPUT/native"
"$OUTPUT/native" probe > "$OUTPUT/prerequisites.json"
python3 - "$OUTPUT/prerequisites.json" <<'PY'
import json, sys
from pathlib import Path
probe = json.loads(Path(sys.argv[1]).read_text())
print(json.dumps(probe, indent=2))
if not all(probe.get(key) is True for key in ('console', 'accessibility', 'screenCapture')):
    raise SystemExit('Minimighty native UI prerequisites unavailable; no app was built or launched')
PY
if [[ "$MODE" == --check-prerequisites ]]; then
    exit 0
fi
./script/preflight.sh
./script/build_and_run.sh --stage-local-api-e2e
PR775_SCALE=1.0 python3 script/terminal-lifecycle-e2e/run.py --project-transcripts --output "$OUTPUT/normal"
PR775_SCALE=1.5 python3 script/terminal-lifecycle-e2e/run.py --project-transcripts --output "$OUTPUT/enlarged"
