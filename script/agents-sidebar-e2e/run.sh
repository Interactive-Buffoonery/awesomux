#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
"$ROOT/script/check-toolchain.sh"
"$ROOT/script/ensure_ghostty_artifacts.sh"
HARNESS="$ROOT/.build/agents-sidebar-e2e"
mkdir -p "$HARNESS/Sources/Harness"
ln -sfn "$ROOT/script/agents-sidebar-e2e/Driver.swift" "$HARNESS/Sources/Harness/Driver.swift"
cat > "$HARNESS/Package.swift" <<MANIFEST
// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "AgentsSidebarScenarios", platforms: [.macOS(.v15)], dependencies: [.package(name: "awesomux", path: "$ROOT")], targets: [.executableTarget(name: "Harness", dependencies: [.product(name: "AwesoMuxCore", package: "awesomux")])])
MANIFEST
swift run --package-path "$HARNESS" Harness
