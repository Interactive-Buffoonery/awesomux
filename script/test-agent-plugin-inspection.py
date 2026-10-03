#!/usr/bin/env python3
"""Run from the repository root; no SwiftPM build or provider mutation."""
from pathlib import Path
import subprocess
import tempfile

workspace = tempfile.TemporaryDirectory(prefix="awesomux-plugin-inspection-")
folder = Path(workspace.name)
source = Path("Sources/awesoMux/Services/AgentPluginTemplateRenderer.swift").read_text()

def method(name):
    start = source.index("    private func " + name)
    end = source.index("\n    }", start) + 6
    return source[start:end].replace("private func", "func")

header = '''import Foundation
struct AgentRuntimeEnvironment { static let hookExecutableName = "awesoMuxAgentHook" }
struct AppRuntimeProfile { static let productionBundleIdentifier = "com.example.app" }
struct Renderer {
static func isShellSafeBundleIdentifier(_ value: String) -> Bool { true }
var bundleIdentifier = "com.example.app"
'''
(folder / "check.swift").write_text(header + method("helperResolutionSnippet") + "\n" + method("shellSingleQuoted") + "\n}\n" + r'''
actor Counter {
    var ids: [String] = []
    func probe(_ id: String) -> Bool? { ids.append(id); return false }
}
@main struct Check {
    static func data(_ command: String, other: String = "") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["other": other, "hooks": ["Stop": [["hooks": [["command": command]]]]]])
    }
    static func main() async throws {
        let paths = ["/Applications/awesoMux.app/Contents/MacOS/awesoMuxAgentHook", "/Applications/Terminal Tools/awesoMux.app/Contents/MacOS/awesoMuxAgentHook", "/Applications/eD!'s \"Tools\"\\folder/awesoMux.app/Contents/MacOS/awesoMuxAgentHook"]
        let rendered = paths.map { Renderer().helperResolutionSnippet(helperPath: $0) }
        for (path, command) in zip(paths, rendered) {
            precondition(AgentPluginDeployedCopyInspector.bakedHelperPaths(in: command) == [path, path])
            let deployed = try data(command)
            let current = try data(rendered[0])
            precondition(!AgentPluginDeployedCopyInspector.contentDrift(deployed: deployed, rendered: current))
        }
        let deployed = try data(rendered[0], other: paths[0])
        let current = try data(rendered[0], other: paths[1])
        precondition(AgentPluginDeployedCopyInspector.contentDrift(deployed: deployed, rendered: current))
        let changedCommand = try data(rendered[0] + "; echo changed")
        let originalCommand = try data(rendered[0])
        precondition(AgentPluginDeployedCopyInspector.contentDrift(
            deployed: changedCommand, rendered: originalCommand
        ))
        precondition(AgentPluginDeployedCopyInspector.bakedHelperPaths(in: "'/tmp/awesoMuxAgentHook-extra'").isEmpty)
        precondition(AgentPluginDeployedCopyInspector.bakedHelperPaths(in: "'/tmp/awesoMuxAgentHook'junk").isEmpty)
        precondition(AgentPluginDeployedCopyInspector.bakedHelperPaths(in: "prefix'/tmp/awesoMuxAgentHook'").isEmpty)
        precondition(AgentPluginDeployedCopyInspector.bakedHelperPaths(in: "'/tmp/awesoMuxAgentHook").isEmpty)
        let counter = Counter()
        let finding = await AgentPluginDeployedCopyInspector.assess(deployedHooksData: try data(rendered[1]), renderedHooksData: try data(rendered[0]), ladderProbe: { await counter.probe($0) })
        precondition(finding?.helperReachable == false)
        let ids = await counter.ids
        precondition(ids == ["com.example.app"])
        let unknown = await AgentPluginDeployedCopyInspector.assess(deployedHooksData: try data(rendered[1]), renderedHooksData: try data(rendered[0]), ladderProbe: { _ in nil })
        precondition(unknown?.helperReachable == true && unknown?.differsFromCurrentRender == false)
        let otherCommand = Renderer(bundleIdentifier: "com.other.app").helperResolutionSnippet(helperPath: paths[0])
        let distinct = Counter()
        let different = await AgentPluginDeployedCopyInspector.assess(deployedHooksData: try data(rendered[1]), renderedHooksData: try data(otherCommand), ladderProbe: { await distinct.probe($0) })
        precondition(different?.differsFromCurrentRender == true)
        let distinctIDs = await distinct.ids
        precondition(Set(distinctIDs) == Set(["com.example.app", "com.other.app"]) && distinctIDs.count == 2)
        let cancelled = Task {
            await AgentPluginDeployedCopyInspector.assess(deployedHooksData: try data(rendered[1]), renderedHooksData: try data(otherCommand), ladderProbe: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return nil
            })
        }
        let cancelledFinding = try await cancelled.value
        precondition(cancelledFinding == nil)
        let executable = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("awesoMuxAgentHook")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let liveCommand = Renderer().helperResolutionSnippet(helperPath: executable.path)
        let unnecessary = Counter()
        let live = await AgentPluginDeployedCopyInspector.assess(deployedHooksData: try data(liveCommand), renderedHooksData: try data(liveCommand), ladderProbe: { await unnecessary.probe($0) })
        precondition(live?.helperReachable == true && live?.differsFromCurrentRender == false)
        let unneededIDs = await unnecessary.ids
        precondition(unneededIDs.isEmpty)
        print("PASS: renderer snippet, spaces/apostrophe/quotes/backslash, command-only masking, exact executable suffix, one lookup per ID, dead and unknown ladders")
    }
}
''')
services = Path("Sources/awesoMux/Services")
subprocess.run(["swiftc", "-parse-as-library", *[str(services / name) for name in ["AgentPluginDeployedCopyInspector.swift", "ProcessCommandRunner.swift", "CommandRunner.swift"]], str(folder / "check.swift"), "-o", str(folder / "check")], check=True)
with (folder / "check.log").open("w") as log:
    subprocess.run([str(folder / "check"), str(folder)], stdout=log, check=True)
print((folder / "check.log").read_text(), end="")
