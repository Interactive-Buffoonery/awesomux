import Foundation
import Testing
@testable import AwesoMuxCore
@testable import awesoMux

@Suite
struct RemoteMarkdownReferenceTests {
    private func remotePane(
        target: String = "my-purple",
        title: String = "alice@devbox:/repo",
        remoteHost: String? = "devbox",
        remoteSSHTarget: String? = nil,
        remoteWorkingDirectory: String? = nil
    ) -> TerminalPane {
        TerminalPane(
            title: title,
            workingDirectory: "/local",
            remoteHost: remoteHost,
            remoteSSHTarget: remoteSSHTarget,
            remoteWorkingDirectory: remoteWorkingDirectory,
            liveTerminalTitle: title,
            executionPlan: .ssh(SSHExecution(target: RemoteTarget(parsing: target)!))
        )
    }

    @Test func absoluteRemoteMarkdownUsesDeclaredAlias() throws {
        let reference = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md",
                pane: remotePane()
            ))

        #expect(reference.sshTarget == "my-purple")
        #expect(reference.remotePath == "/repo/README.md")
        #expect(reference.origin == "my-purple:/repo/README.md")
    }

    @Test func declaredUserAndAliasArePassedExactly() throws {
        let reference = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md",
                pane: remotePane(target: "alice@my-purple")
            ))

        #expect(reference.sshTarget == "alice@my-purple")
    }

    @Test func titleAndSubmittedTargetCannotRetargetDeclaredPane() throws {
        let reference = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md",
                pane: remotePane(
                    title: "mallory@spoofed:/private",
                    remoteHost: "spoofed",
                    remoteSSHTarget: "submitted-target"
                )
            ))

        #expect(reference.sshTarget == "my-purple")
        #expect(reference.remotePath == "/repo/README.md")
    }

    @Test func localPaneWithRemotePresentationCannotFetch() {
        let pane = TerminalPane(
            title: "alice@devbox:/repo",
            workingDirectory: "/local",
            remoteHost: "devbox",
            remoteSSHTarget: "devbox",
            liveTerminalTitle: "alice@devbox:/repo",
            executionPlan: .local
        )

        #expect(RemoteMarkdownReference.make(payload: "/repo/README.md", pane: pane) == nil)
    }

    @Test func declaredRemoteWorksWithoutObservedHost() throws {
        let reference = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md",
                pane: remotePane(remoteHost: nil)
            ))

        #expect(reference.sshTarget == "my-purple")
    }

    @Test func absoluteRemoteMarkdownStripsTrailingSentencePeriod() throws {
        #expect(RemoteMarkdownReference.isPotentialPayload("/repo/README.md."))
        let reference = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md.",
                pane: remotePane()
            ))
        #expect(reference.remotePath == "/repo/README.md")
    }

    @Test func relativeRemoteMarkdownUsesReportedRemoteDirectory() throws {
        let reference = try #require(
            RemoteMarkdownReference.make(
                payload: "docs/plan.md",
                pane: remotePane(remoteWorkingDirectory: "~/repo")
            ))

        #expect(reference.remotePath == "~/repo/docs/plan.md")
    }

    @Test func relativeRemoteMarkdownIgnoresTitleDirectory() {
        let pane = remotePane(title: "alice@devbox:~/repo")
        #expect(RemoteMarkdownReference.make(payload: "docs/plan.md", pane: pane) == nil)
    }

    @Test func relativeRemoteMarkdownRejectsInvalidReportedDirectories() {
        for directory in [nil, "repo", "~other/repo", ""] as [String?] {
            #expect(
                RemoteMarkdownReference.make(
                    payload: "docs/plan.md",
                    pane: remotePane(remoteWorkingDirectory: directory)
                ) == nil)
        }
    }

    @Test func relativeRemoteMarkdownNormalizesWithoutEscapingTildeRoot() throws {
        let normalized = try #require(
            RemoteMarkdownReference.make(
                payload: "docs/../plan.md",
                pane: remotePane(remoteWorkingDirectory: "~/repo")
            ))
        #expect(normalized.remotePath == "~/repo/plan.md")

        #expect(
            RemoteMarkdownReference.make(
                payload: "../../plan.md",
                pane: remotePane(remoteWorkingDirectory: "~/repo")
            ) == nil)
    }

    @Test func remoteMarkdownRejectsUnsafeOrUnsupportedPaths() {
        let pane = remotePane()
        #expect(RemoteMarkdownReference.make(payload: "/repo/script.sh", pane: pane) == nil)
        #expect(RemoteMarkdownReference.make(payload: "/repo/e\u{202E}vil.md", pane: pane) == nil)
        #expect(RemoteMarkdownReference.make(payload: "~other/notes.md", pane: pane) == nil)
    }

    @Test func dashLeadingDeclaredTargetIsRejected() {
        let pane = remotePane(target: "-i@devbox")
        #expect(RemoteMarkdownReference.make(payload: "/repo/README.md", pane: pane) == nil)
    }

    @Test func fileURLPayloadUsesRemotePath() throws {
        let reference = try #require(
            RemoteMarkdownReference.make(
                payload: "file:///repo/docs/plan.markdown",
                pane: remotePane()
            ))
        #expect(reference.remotePath == "/repo/docs/plan.markdown")
    }

    @Test func cacheIdentitySeparatesHostsAndUsers() throws {
        let fetcher = RemoteMarkdownSnapshotFetcher()
        let hostA = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md",
                pane: remotePane(target: "host-a")
            ))
        let hostB = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md",
                pane: remotePane(target: "host-b")
            ))
        let userA = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md",
                pane: remotePane(target: "alice@host-a")
            ))

        #expect(fetcher.cacheFileName(for: hostA) != fetcher.cacheFileName(for: hostB))
        #expect(fetcher.cacheFileName(for: hostA) != fetcher.cacheFileName(for: userA))
    }

    @Test func shellSingleQuoteEscapesQuotes() {
        #expect(RemoteMarkdownSnapshotFetcher.shellSingleQuoted("a'b.md") == "'a'\\''b.md'")
    }

    @Test func markdownInlineCodeStripsBackticks() {
        #expect(RemoteMarkdownSnapshotFetcher.markdownInlineCode("dev:/tmp/a`b.md") == "dev:/tmp/ab.md")
    }
}
