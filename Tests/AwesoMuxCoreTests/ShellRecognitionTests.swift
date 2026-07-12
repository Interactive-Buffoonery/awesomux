// Tests/AwesoMuxCoreTests/ShellRecognitionTests.swift
import Testing
@testable import AwesoMuxCore

@Suite("ShellRecognition")
struct ShellRecognitionTests {
    @Test("basename strips path and login-shell dash")
    func basename() {
        #expect(ShellRecognition.basename("/bin/zsh") == "zsh")
        #expect(ShellRecognition.basename("-zsh") == "zsh")
        #expect(ShellRecognition.basename("/opt/homebrew/bin/fish") == "fish")
        #expect(ShellRecognition.basename("make") == "make")
    }

    @Test("recognizes login shells, rejects commands")
    func recognizes() {
        for shell in ["zsh", "/bin/bash", "-fish", "/usr/bin/nu", "pwsh"] {
            #expect(ShellRecognition.isRecognizedShell(shell))
        }
        for command in ["vim", "node", "/usr/bin/make", "claude", "ssh"] {
            #expect(!ShellRecognition.isRecognizedShell(command))
        }
    }
}
