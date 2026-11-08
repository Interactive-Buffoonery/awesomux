#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
"$ROOT/script/check-toolchain.sh"
HARNESS="$ROOT/.build/menu-styling-e2e"
mkdir -p "$HARNESS/Sources/Fixture"
for source in AppDropdown AppDropdownPresenter AppMenuStyle; do
    ln -sfn "$ROOT/Sources/awesoMux/Views/$source.swift" "$HARNESS/Sources/Fixture/$source.swift"
done
for source in FloatingSwiftUIPanelWindow FloatingPanelEventPolicy; do
    ln -sfn "$ROOT/Sources/awesoMux/Services/$source.swift" "$HARNESS/Sources/Fixture/$source.swift"
done
ln -sfn "$ROOT/script/menu-styling-e2e/Fixture.swift" "$HARNESS/Sources/Fixture/Fixture.swift"
cat > "$HARNESS/Package.swift" <<MANIFEST
// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "MenuStylingFixture", platforms: [.macOS(.v15)], dependencies: [.package(name: "awesomux", path: "$ROOT")], targets: [.executableTarget(name: "Fixture", dependencies: [.product(name: "DesignSystem", package: "awesomux")])])
MANIFEST
swift build --package-path "$HARNESS"
BIN="$(swift build --package-path "$HARNESS" --show-bin-path)/Fixture"
BUNDLE="$HARNESS/MenuStylingFixture.app"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BIN" "$BUNDLE/Contents/MacOS/MenuStylingFixture"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.awesomux.menu-styling-fixture</string><key>CFBundleExecutable</key><string>MenuStylingFixture</string><key>CFBundleName</key><string>MenuStylingFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
codesign --force --sign - "$BUNDLE"
printf 'Native fixture ready: %s\n' "$BUNDLE"
