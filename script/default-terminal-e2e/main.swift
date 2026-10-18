// Non-destructive integration checks: all default-app writes use a fake registrar.
// Failure cases: cancellation/partial association, unregistered app, unsupported or
// non-local files, directories, shell metacharacters, and non-executable files.
import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
func check() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("hello ' $(printf INJECTED).command")
    try Data("# fixture; never executed\n".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    let request = try TerminalFileOpenRequest(url: file)
    precondition(request.workingDirectory == directory.path)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-n", "-c", request.command]
    try process.run()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0)
    var shells = ["/bin/sh", "/bin/bash", "/bin/zsh"]
    if let fish = ProcessInfo.processInfo.environment["AWESOMUX_E2E_FISH"], !fish.isEmpty {
        shells.append(fish)
    } else {
        print("SKIP: fish round-trip (set AWESOMUX_E2E_FISH to an executable fish path).")
    }
    for name in ["ordinary.command", "quotes ' and \\ backslash.command", "x\\'; printf INJECTED; #.command"] {
        let candidate = directory.appendingPathComponent(name)
        try Data().write(to: candidate)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.path)
        let quoted = try TerminalFileOpenRequest(url: candidate).command
        for shell in shells {
            let echo = Process()
            let output = Pipe()
            echo.executableURL = URL(fileURLWithPath: shell)
            echo.arguments = (shell.hasSuffix("/fish") ? ["--no-config"] : []) + ["-c", "printf '%s' " + quoted]
            echo.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path]
            echo.standardOutput = output
            try echo.run()
            let echoed = output.fileHandleForReading.readDataToEndOfFile()
            echo.waitUntilExit()
            guard echo.terminationStatus == 0 && String(data: echoed, encoding: .utf8) == candidate.path else {
                print("FAIL: \(shell) filename round-trip, command=\(quoted.debugDescription), output=\(String(decoding: echoed, as: UTF8.self).debugDescription)")
                exit(1)
            }
        }
    }
    print("PASS: exact filename round-trip without injected output in \(shells.count) shells.")
    for invalid in [directory, URL(string: "https://example.com/a.command")!] {
        do { _ = try TerminalFileOpenRequest(url: invalid); preconditionFailure("Accepted invalid file") }
        catch {}
    }
    let control = directory.appendingPathComponent("bad\n.command")
    try Data().write(to: control)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: control.path)
    do { _ = try TerminalFileOpenRequest(url: control); preconditionFailure("Accepted terminal control characters") }
    catch {}
    for scalar in ["\u{202E}", "\u{2066}"] {
        let hidden = directory.appendingPathComponent("hidden\(scalar).command")
        try Data().write(to: hidden)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hidden.path)
        do { _ = try TerminalFileOpenRequest(url: hidden); preconditionFailure("Accepted hidden path formatting") }
        catch {}
    }
    let text = directory.appendingPathComponent("notes.txt")
    try Data().write(to: text)
    do { _ = try TerminalFileOpenRequest(url: text); preconditionFailure("Accepted non-executable") }
    catch {}
    let executable = directory.appendingPathComponent("program")
    try Data().write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    _ = try TerminalFileOpenRequest(url: executable)

    let app = URL(fileURLWithPath: "/Applications/awesoMux.app")
    var defaults: [String: URL] = [:]
    var registrations: [String] = []
    let model = DefaultTerminalSettingsModel(
        applicationURL: app,
        defaultApplication: { defaults[$0.identifier] },
        setDefaultApplication: { type in
            registrations.append(type.identifier)
            defaults[type.identifier] = app
        }
    )
    model.refresh()
    precondition(!model.isDefault)
    await model.makeDefault()
    precondition(model.isDefault && model.errorMessage == nil)
    precondition(Set(registrations) == Set(["public.unix-executable", "com.apple.terminal.shell-script"]))
    defaults.removeAll()
    let failing = DefaultTerminalSettingsModel(
        applicationURL: app, defaultApplication: { defaults[$0.identifier] },
        setDefaultApplication: { type in
            if type == .unixExecutable { defaults[type.identifier] = app }
            else { throw CocoaError(.userCancelled) }
        }
    )
    await failing.makeDefault()
    precondition(!failing.isDefault && failing.errorMessage != nil && !failing.isUpdating)
    precondition(defaults.count == 1, "Partial success must not report all associations complete")
    print("PASS: terminal-file validation/quoting and default-app registration success/failure; no files executed or OS defaults changed.")
    print("Fixtures retained at \(directory.path)")
}
try await check()
