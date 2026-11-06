#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec heavy-gate bash -s -- "$ROOT" <<'JOB'
set -euo pipefail
ROOT="$1"
HARNESS="$ROOT/.build/agent-disclosure-e2e"
mkdir -p "$HARNESS/Sources/Harness"
ln -sfn "$ROOT/Sources/DesignSystem" "$HARNESS/Sources/DesignSystem"
ln -sfn "$ROOT/Sources/awesoMux/Views/Settings/Panes/Components/AgentIntegrationDisclosureRow.swift" "$HARNESS/Sources/Harness/AgentIntegrationDisclosureRow.swift"
ln -sfn "$ROOT/script/agent-disclosure-e2e/Driver.swift" "$HARNESS/Sources/Harness/Driver.swift"
cat > "$HARNESS/Package.swift" <<'MANIFEST'
// swift-tools-version: 6.3
import PackageDescription
let package = Package(
    name: "AgentDisclosureE2E",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "DesignSystem", resources: [.copy("Resources/Fonts")]),
        .executableTarget(name: "Harness", dependencies: ["DesignSystem"]),
    ]
)
MANIFEST
swift build --package-path "$HARNESS" --product Harness
BIN="$(swift build --package-path "$HARNESS" --show-bin-path)"
APP="$HARNESS/AgentDisclosureE2E.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/Harness" "$APP/Contents/MacOS/Harness"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Harness</string>
<key>CFBundleIdentifier</key><string>app.awesomux.agent-disclosure-e2e</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
"$APP/Contents/MacOS/Harness"
JOB
