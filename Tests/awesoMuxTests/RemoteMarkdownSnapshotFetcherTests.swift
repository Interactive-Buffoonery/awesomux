import Foundation
import Testing
@testable import AwesoMuxCore
@testable import awesoMux

@Suite
struct RemoteMarkdownReferenceTests {
    @Test func absoluteRemoteMarkdownUsesTitleUserAndPaneHost() throws {
        let pane = TerminalPane(
            title: "alice@devbox:/repo",
            workingDirectory: "/local",
            remoteHost: "devbox",
            liveTerminalTitle: "alice@devbox:/repo"
        )

        let reference = try #require(RemoteMarkdownReference.make(
            payload: "/repo/README.md",
            pane: pane
        ))

        #expect(reference.sshTarget == "alice@devbox")
        #expect(reference.remotePath == "/repo/README.md")
        #expect(reference.origin == "alice@devbox:/repo/README.md")
    }

    // Same libghostty bare-path artifact MarkdownLinkIntercept fixes for
    // local panes (a path mentioned at the end of a sentence, e.g.
    // "see /repo/README.md.") also reaches remote panes via the identical
    // regex — without stripping it here too, isPotentialPayload's extension
    // check fails and the click falls through to local resolution instead
    // of fetching the remote snapshot.
    @Test func absoluteRemoteMarkdownStripsTrailingSentencePeriod() throws {
        let pane = TerminalPane(
            title: "alice@devbox:/repo",
            workingDirectory: "/local",
            remoteHost: "devbox",
            liveTerminalTitle: "alice@devbox:/repo"
        )

        #expect(RemoteMarkdownReference.isPotentialPayload("/repo/README.md."))

        let reference = try #require(RemoteMarkdownReference.make(
            payload: "/repo/README.md.",
            pane: pane
        ))

        #expect(reference.remotePath == "/repo/README.md")
    }

    @Test func absoluteRemoteMarkdownPrefersSubmittedSSHTarget() throws {
        let pane = TerminalPane(
            title: "alice@devbox:/repo",
            workingDirectory: "/local",
            remoteHost: "devbox",
            remoteSSHTarget: "my-purple",
            liveTerminalTitle: "alice@devbox:/repo"
        )

        let reference = try #require(RemoteMarkdownReference.make(
            payload: "/repo/README.md",
            pane: pane
        ))

        #expect(reference.sshTarget == "my-purple")
        #expect(reference.origin == "my-purple:/repo/README.md")
    }

    @Test func relativeRemoteMarkdownUsesTitleDirectory() throws {
        let pane = TerminalPane(
            title: "alice@devbox:~/repo",
            workingDirectory: "/local",
            remoteHost: "devbox",
            liveTerminalTitle: "alice@devbox:~/repo"
        )

        let reference = try #require(RemoteMarkdownReference.make(
            payload: "docs/plan.md",
            pane: pane
        ))

        #expect(reference.remotePath == "~/repo/docs/plan.md")
    }

    @Test func relativeRemoteMarkdownUsesCachedRemoteDirectoryWhenToolOwnsTitle() throws {
        let pane = TerminalPane(
            title: "codex",
            workingDirectory: "/local",
            remoteHost: "devbox",
            remoteWorkingDirectory: "~/repo",
            liveTerminalTitle: "codex"
        )

        let reference = try #require(RemoteMarkdownReference.make(
            payload: "docs/plan.md",
            pane: pane
        ))

        #expect(reference.remotePath == "~/repo/docs/plan.md")
    }

    @Test func bracketedIPv6TitleCanSupplyUserAndDirectory() throws {
        let pane = TerminalPane(
            title: "ed@[2001:db8::1]:~/repo",
            workingDirectory: "/local",
            remoteHost: "[2001:db8::1]",
            liveTerminalTitle: "ed@[2001:db8::1]:~/repo"
        )

        let reference = try #require(RemoteMarkdownReference.make(
            payload: "docs/plan.md",
            pane: pane
        ))

        #expect(reference.sshTarget == "ed@[2001:db8::1]")
        #expect(reference.remotePath == "~/repo/docs/plan.md")
    }

    @Test func nonPromptTitleDoesNotSupplyUser() throws {
        let pane = TerminalPane(
            title: "ed@devbox - Mail",
            workingDirectory: "/local",
            remoteHost: "devbox",
            liveTerminalTitle: "ed@devbox - Mail"
        )

        let reference = try #require(RemoteMarkdownReference.make(
            payload: "/repo/README.md",
            pane: pane
        ))

        #expect(reference.sshTarget == "devbox")
    }

    @Test func relativeRemoteMarkdownWithoutTitleDirectoryIsRejected() {
        let pane = TerminalPane(
            title: "alice@devbox",
            workingDirectory: "/local",
            remoteHost: "devbox",
            liveTerminalTitle: "alice@devbox"
        )

        #expect(RemoteMarkdownReference.make(payload: "docs/plan.md", pane: pane) == nil)
    }

    @Test func remoteMarkdownRejectsUnsafeOrUnsupportedPaths() {
        let pane = TerminalPane(
            title: "alice@devbox:/repo",
            workingDirectory: "/local",
            remoteHost: "devbox",
            liveTerminalTitle: "alice@devbox:/repo"
        )

        #expect(RemoteMarkdownReference.make(payload: "/repo/script.sh", pane: pane) == nil)
        #expect(RemoteMarkdownReference.make(payload: "/repo/e\u{202E}vil.md", pane: pane) == nil)
        #expect(RemoteMarkdownReference.make(payload: "~other/notes.md", pane: pane) == nil)
    }

    @Test func dashLeadingTitleUserYieldsNoSSHTargetInjection() {
        // A spoofed title whose username begins with `-` must not produce an SSH
        // destination (`-i@devbox`) that ssh would parse as an option.
        let pane = TerminalPane(
            title: "-i@devbox:/repo",
            workingDirectory: "/local",
            remoteHost: "devbox",
            liveTerminalTitle: "-i@devbox:/repo"
        )

        #expect(RemoteMarkdownReference.make(payload: "/repo/README.md", pane: pane) == nil)
    }

    @Test func fileURLPayloadUsesRemotePath() throws {
        let pane = TerminalPane(
            title: "alice@devbox:/repo",
            workingDirectory: "/local",
            remoteHost: "devbox",
            liveTerminalTitle: "alice@devbox:/repo"
        )

        let reference = try #require(RemoteMarkdownReference.make(
            payload: "file:///repo/docs/plan.markdown",
            pane: pane
        ))

        #expect(reference.remotePath == "/repo/docs/plan.markdown")
    }

    @Test func shellSingleQuoteEscapesQuotes() {
        #expect(RemoteMarkdownSnapshotFetcher.shellSingleQuoted("a'b.md") == "'a'\\''b.md'")
    }

    @Test func markdownInlineCodeStripsBackticks() {
        #expect(RemoteMarkdownSnapshotFetcher.markdownInlineCode("dev:/tmp/a`b.md") == "dev:/tmp/ab.md")
    }
}
