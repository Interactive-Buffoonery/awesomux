#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
ARTIFACT_DIR="${1:?Usage: ./script/codex-client-events-e2e/run.sh /absolute/artifact-directory}"
mkdir -p "$ARTIFACT_DIR"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"
FIXTURES="$ROOT_DIR/script/codex-client-events-e2e"

swift build --product awesoMuxAgentHook > "$ARTIFACT_DIR/build.log" 2>&1
BIN_DIR="$(swift build --show-bin-path)"
python3 "$FIXTURES/helper-check.py" "$BIN_DIR/awesoMuxAgentHook" > "$ARTIFACT_DIR/helper.log" 2>&1

# SwiftPM's Xcode and native build systems expose different object layouts.
OBJECTS=()
for target in AwesoMuxCore AwesoMuxBridgeProtocol UnicodeHygiene Markdown cmark-gfm cmark-gfm-extensions AwesoMuxLocalAPI SecureFileIO CAtomic; do
    if [[ -f "$BIN_DIR/$target.o" ]]; then
        OBJECTS+=("$BIN_DIR/$target.o")
    else
        for object in "$BIN_DIR/$target.build/"*.o; do
            [[ -f "$object" ]] || { echo "Missing objects for $target" >&2; exit 1; }
            OBJECTS+=("$object")
        done
    fi
done
swiftc "$FIXTURES/parser-check.swift" -o "$ARTIFACT_DIR/parser-check" \
    -I "$BIN_DIR" -I "$BIN_DIR/Modules" \
    -I .build/checkouts/swift-markdown/Sources/CAtomic/include \
    -I .build/checkouts/swift-cmark/src/include \
    -I .build/checkouts/swift-cmark/extensions/include \
    "${OBJECTS[@]}" > "$ARTIFACT_DIR/parser-build.log" 2>&1
"$ARTIFACT_DIR/parser-check" > "$ARTIFACT_DIR/parser.log" 2>&1
swiftc "$FIXTURES/tracker-check.swift" \
    Sources/AwesoMuxCore/Models/AgentClientStatusEvidence.swift \
    Sources/AwesoMuxCore/Services/AgentClientStatusTracker.swift \
    -o "$ARTIFACT_DIR/tracker-check" > "$ARTIFACT_DIR/tracker-build.log" 2>&1
"$ARTIFACT_DIR/tracker-check" > "$ARTIFACT_DIR/tracker.log" 2>&1
swiftc -parse-as-library "$FIXTURES/runtime.swift" -o "$ARTIFACT_DIR/runtime-check" \
    -I "$BIN_DIR" -I "$BIN_DIR/Modules" \
    -I .build/checkouts/swift-markdown/Sources/CAtomic/include \
    -I .build/checkouts/swift-cmark/src/include \
    -I .build/checkouts/swift-cmark/extensions/include \
    "${OBJECTS[@]}" > "$ARTIFACT_DIR/runtime-build.log" 2>&1
"$ARTIFACT_DIR/runtime-check" > "$ARTIFACT_DIR/runtime.log" 2>&1
swiftc -swift-version 6 -parse-as-library "$FIXTURES/bridge-check.swift" \
    Sources/awesoMux/Services/AgentRuntimeEventBridge.swift \
    Sources/awesoMux/Services/AgentRuntimeEventFile.swift \
    -o "$ARTIFACT_DIR/bridge-check" \
    -I "$BIN_DIR" -I "$BIN_DIR/Modules" \
    -I .build/checkouts/swift-markdown/Sources/CAtomic/include \
    -I .build/checkouts/swift-cmark/src/include \
    -I .build/checkouts/swift-cmark/extensions/include \
    "${OBJECTS[@]}" > "$ARTIFACT_DIR/bridge-build.log" 2>&1
"$ARTIFACT_DIR/bridge-check" "$ARTIFACT_DIR/bridge-files" > "$ARTIFACT_DIR/bridge.log" 2>&1
cat "$ARTIFACT_DIR/bridge.log" "$ARTIFACT_DIR/helper.log" "$ARTIFACT_DIR/parser.log" "$ARTIFACT_DIR/tracker.log" "$ARTIFACT_DIR/runtime.log"
echo "Artifacts: $ARTIFACT_DIR"
