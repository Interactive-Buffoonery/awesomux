#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != --self-check ) ]]; then
    echo "Usage: $0 [--self-check]" >&2
    exit 2
fi
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
"$ROOT/script/check-toolchain.sh"
HARNESS="$ROOT/.build/annotation-keyboard-e2e"
FIXTURE_ID="$(printf '%s' "$ROOT" | shasum -a 256 | cut -c1-12)"
mkdir -p "$HARNESS/Sources/Fixture"
for source in CommentPopover DocumentNoteSheet RichInputComposer AnnotationSaveRecovery; do
    ln -sfn "$ROOT/Sources/awesoMux/Views/Markdown/$source.swift" "$HARNESS/Sources/Fixture/$source.swift"
done
ln -sfn "$ROOT/Sources/awesoMux/Views/Settings/Components/SettingsSegmented.swift" "$HARNESS/Sources/Fixture/SettingsSegmented.swift"
# The fixture posts announcements without starting the terminal app shell.
cat > "$HARNESS/Sources/Fixture/FixtureAnnouncer.swift" <<'SWIFT'
import AppKit
@MainActor enum TerminalAccessibilityAnnouncer {
    static func announce(_ message: String) {
        NSAccessibility.post(element: NSApp!, notification: .announcementRequested, userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
SWIFT
for source in Fixture SelfCheck; do
    ln -sfn "$ROOT/script/annotation-keyboard-e2e/$source.swift" "$HARNESS/Sources/Fixture/$source.swift"
done
cat > "$HARNESS/Package.swift" <<MANIFEST
// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "AnnotationKeyboardFixture", platforms: [.macOS(.v15)], dependencies: [.package(name: "awesomux", path: "$ROOT")], targets: [.executableTarget(name: "Fixture", dependencies: [.product(name: "DesignSystem", package: "awesomux"), .product(name: "AwesoMuxCore", package: "awesomux")])])
MANIFEST
swift build --package-path "$HARNESS"
BIN="$(swift build --package-path "$HARNESS" --show-bin-path)/Fixture"
BUNDLE="$HARNESS/AnnotationKeyboardFixture.app"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BIN" "$BUNDLE/Contents/MacOS/AnnotationKeyboardFixture"
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.awesomux.annotation-keyboard-fixture.$FIXTURE_ID</string><key>CFBundleExecutable</key><string>AnnotationKeyboardFixture</string><key>CFBundleName</key><string>Annotation Keyboard Fixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
codesign --force --sign - "$BUNDLE"
printf 'Native fixture ready: %s\n' "$BUNDLE"
if [[ "${1:-}" == --self-check ]]; then
    "$BUNDLE/Contents/MacOS/AnnotationKeyboardFixture" --self-check
fi
