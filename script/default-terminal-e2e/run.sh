#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

usage() {
  printf 'Usage: %s [--output DIRECTORY]\n' "$0" >&2
}

if [[ ${1:-} == "--output" ]]; then
  [[ $# -eq 2 ]] || { usage; exit 2; }
  OUTPUT="$2"
  mkdir -p "$(dirname "$OUTPUT")"
  if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
    printf 'error: output path already exists: %s\n' "$OUTPUT" >&2
    exit 1
  fi
  if ! mkdir "$OUTPUT" 2>/dev/null; then
    printf 'error: could not create new output path: %s\n' "$OUTPUT" >&2
    exit 1
  fi
elif [[ $# -eq 0 ]]; then
  OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/awesomux-default-terminal-e2e.XXXXXX")"
else
  usage
  exit 2
fi

OUTPUT="$(cd "$OUTPUT" && pwd)"
exec > >(tee "$OUTPUT/run.log") 2>&1
trap 'result=$?; if [[ $result -ne 0 ]]; then printf "FAIL: evidence retained at %s\n" "$OUTPUT"; fi' EXIT

inputs=(
  "Sources/awesoMux/Services/DefaultTerminalSettingsModel.swift"
  "Sources/awesoMux/Services/TerminalFileOpenRequest.swift"
  "Tests/AwesoMuxTestSupport/ProcessBoundedWait.swift"
  "Tests/AwesoMuxTestSupport/ProcessOutputCapture.swift"
  "script/build_and_run.sh"
  "script/default-terminal-e2e/main.swift"
  "script/default-terminal-e2e/run.sh"
)
source_head="$(git -C "$ROOT" rev-parse HEAD)"
source_diff_sha256="$(git -C "$ROOT" diff --binary --no-ext-diff --no-textconv HEAD | shasum -a 256 | awk '{print $1}')"
{
  printf 'head-before %s\n' "$source_head"
  printf 'git-diff-head-binary-sha256-before %s\n' "$source_diff_sha256"
  (
    cd "$ROOT"
    shasum -a 256 "${inputs[@]}"
  )
} > "$OUTPUT/source-receipt.txt"

swiftc -swift-version 6 -module-cache-path "$OUTPUT/module-cache" \
  "$ROOT/Sources/awesoMux/Services/DefaultTerminalSettingsModel.swift" \
  "$ROOT/Sources/awesoMux/Services/TerminalFileOpenRequest.swift" \
  "$ROOT/Tests/AwesoMuxTestSupport/ProcessBoundedWait.swift" \
  "$ROOT/Tests/AwesoMuxTestSupport/ProcessOutputCapture.swift" \
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

source_head_after="$(git -C "$ROOT" rev-parse HEAD)"
source_diff_sha256_after="$(git -C "$ROOT" diff --binary --no-ext-diff --no-textconv HEAD | shasum -a 256 | awk '{print $1}')"
{
  printf 'head-after %s\n' "$source_head_after"
  printf 'git-diff-head-binary-sha256-after %s\n' "$source_diff_sha256_after"
} >> "$OUTPUT/source-receipt.txt"
if [[ "$source_head_after" != "$source_head" || "$source_diff_sha256_after" != "$source_diff_sha256" ]]; then
  printf 'FAIL: source changed while the harness was running; discard this result.\n' >&2
  exit 1
fi

printf 'Report: %s/report.txt\n' "$OUTPUT"
printf 'Run log: %s/run.log\n' "$OUTPUT"
printf 'Source receipt: %s/source-receipt.txt\n' "$OUTPUT"
