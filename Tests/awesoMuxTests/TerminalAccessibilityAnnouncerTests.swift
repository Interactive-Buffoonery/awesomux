import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Terminal accessibility announcements")
struct TerminalAccessibilityAnnouncerTests {
    @Test func remoteMarkdownAnnouncementsDescribeEveryOutcome() {
        let snapshot = RemoteMarkdownSnapshot(
            fileURL: URL(fileURLWithPath: "/tmp/example.md"),
            identity: ResourceIdentity(location: .local, path: ResourcePath(rawValue: "/tmp/example.md"))
        )

        #expect(TerminalAccessibilityAnnouncer.remoteMarkdownAnnouncement(for: .fresh(snapshot)) == "Remote Markdown loaded.")
        #expect(TerminalAccessibilityAnnouncer.remoteMarkdownAnnouncement(for: .cached(snapshot)).contains("stale"))
        #expect(TerminalAccessibilityAnnouncer.remoteMarkdownAnnouncement(for: .failureDocument(snapshot)).contains("failure document"))
    }
    @Test("settings errors are announced when present")
    func settingsErrors() {
        var announcements: [String] = []

        TerminalAccessibilityAnnouncer.announceSettingsError(nil) { announcements.append($0) }
        TerminalAccessibilityAnnouncer.announceSettingsError("Could not save settings") {
            announcements.append($0)
        }

        #expect(announcements == ["Could not save settings"])
    }

    @Test("workspace close announcement for clean or unknown process exit")
    func workspaceCloseAnnouncementForCleanOrUnknownExit() {
        #expect(
            TerminalAccessibilityAnnouncer.workspaceClosedAfterProcessExitAnnouncement(
                exitedWithError: false
            ) == "Workspace closed. Terminal process exited."
        )
    }

    @Test("workspace close announcement for process error exit")
    func workspaceCloseAnnouncementForErrorExit() {
        #expect(
            TerminalAccessibilityAnnouncer.workspaceClosedAfterProcessExitAnnouncement(
                exitedWithError: true
            ) == "Workspace closed. Terminal process ended with an error."
        )
    }

    @Test("sibling pane error announcement includes non-empty session title")
    func siblingPaneErrorAnnouncementIncludesTitle() {
        #expect(
            TerminalAccessibilityAnnouncer.siblingPaneExitErrorAnnouncement(
                sessionTitle: "Build"
            ) == "Pane in Build ended with an error."
        )
    }

    @Test("sibling pane error announcement tolerates blank session title")
    func siblingPaneErrorAnnouncementToleratesBlankTitle() {
        #expect(
            TerminalAccessibilityAnnouncer.siblingPaneExitErrorAnnouncement(
                sessionTitle: "  "
            ) == "Pane ended with an error."
        )
    }

    @Test("remote disconnect announcement explains disabled background sessions")
    func remoteDisconnectAnnouncementExplainsDisabledBackgroundSessions() {
        #expect(
            TerminalAccessibilityAnnouncer.remoteDisconnectedAnnouncement(
                host: "prod.example",
                paneDescriptor: "pane 2, web",
                backgroundSessionsEnabled: false
            ) == "Disconnected from prod.example in pane 2, web. Background sessions are off. Enable them to reconnect."
        )
    }

    @Test("remote disconnect announcement explains an SSH destination failure")
    func remoteDisconnectAnnouncementExplainsSSHDestinationFailure() {
        #expect(
            TerminalAccessibilityAnnouncer.remoteDisconnectedAnnouncement(
                host: "missing.example"
            )
                == "SSH connection to missing.example failed. Check that the hostname or SSH config alias exists and is reachable. Reconnect available."
        )
    }

    @Test("waiting announcement includes non-empty session title")
    func waitingAnnouncementIncludesTitle() {
        #expect(
            TerminalAccessibilityAnnouncer.waitingForInputAnnouncement(
                sessionTitle: "Build"
            ) == "Agent waiting for your input in Build."
        )
    }

    @Test("waiting announcement tolerates blank session title")
    func waitingAnnouncementToleratesBlankTitle() {
        #expect(
            TerminalAccessibilityAnnouncer.waitingForInputAnnouncement(
                sessionTitle: "  "
            ) == "Agent waiting for your input."
        )
    }

    @Test("waiting announcement distinguishes panes in a split")
    func waitingAnnouncementDistinguishesPanesInSplit() {
        let first = TerminalAccessibilityAnnouncer.waitingForInputAnnouncement(
            sessionTitle: "Build",
            paneDescriptor: "pane 1, api"
        )
        let second = TerminalAccessibilityAnnouncer.waitingForInputAnnouncement(
            sessionTitle: "Build",
            paneDescriptor: "pane 2, web"
        )
        #expect(first == "Agent waiting for your input in Build, pane 1, api.")
        #expect(second == "Agent waiting for your input in Build, pane 2, web.")
        #expect(first != second)
    }

    @Test("ordinal keeps duplicate pane titles distinguishable")
    func ordinalKeepsDuplicatePaneTitlesDistinguishable() {
        // Split clones the seed title, so both panes can be named "Build";
        // the ordinal half of the descriptor is the guaranteed discriminator.
        let first = TerminalAccessibilityAnnouncer.waitingForInputAnnouncement(
            sessionTitle: "Build",
            paneDescriptor: "pane 1, Build"
        )
        let second = TerminalAccessibilityAnnouncer.waitingForInputAnnouncement(
            sessionTitle: "Build",
            paneDescriptor: "pane 2, Build"
        )
        #expect(first != second)
    }

    @Test("waiting announcement with blank session title still names the pane")
    func waitingAnnouncementBlankSessionTitleStillNamesPane() {
        #expect(
            TerminalAccessibilityAnnouncer.waitingForInputAnnouncement(
                sessionTitle: " ",
                paneDescriptor: "pane 2"
            ) == "Agent waiting for your input in pane 2."
        )
    }

    @Test("sibling pane error announcement strips embedded newlines from a pty-controlled title")
    func siblingPaneErrorAnnouncementStripsNewlines() {
        #expect(
            TerminalAccessibilityAnnouncer.siblingPaneExitErrorAnnouncement(
                sessionTitle: "Build\nrm -rf /"
            ) == "Pane in Build rm -rf / ended with an error."
        )
    }

    @Test("waiting announcement truncates an overlong pty-controlled title")
    func waitingAnnouncementTruncatesOverlongTitle() {
        let longTitle = String(repeating: "a", count: 100)
        let announcement = TerminalAccessibilityAnnouncer.waitingForInputAnnouncement(
            sessionTitle: longTitle
        )
        #expect(announcement == "Agent waiting for your input in \(String(repeating: "a", count: 60))….")
    }

    @Test("waiting announcement compacts a pty-influenced pane descriptor")
    func waitingAnnouncementCompactsPaneDescriptor() {
        #expect(
            TerminalAccessibilityAnnouncer.waitingForInputAnnouncement(
                sessionTitle: "Build",
                paneDescriptor: "pane 2,\nweb"
            ) == "Agent waiting for your input in Build, pane 2, web."
        )
        let overlong = String(repeating: "b", count: 100)
        #expect(
            TerminalAccessibilityAnnouncer.waitingForInputAnnouncement(
                sessionTitle: "Build",
                paneDescriptor: overlong
            ) == "Agent waiting for your input in Build, \(String(repeating: "b", count: 60))…."
        )
    }

    @Test("error cleared and waiting announcement combines both facts")
    func errorClearedAndWaitingAnnouncementCombinesBothFacts() {
        #expect(
            TerminalAccessibilityAnnouncer.errorClearedAndWaitingForInputAnnouncement(
                sessionTitle: "Build"
            ) == "Session error cleared. Agent waiting for your input in Build."
        )
        #expect(
            TerminalAccessibilityAnnouncer.errorClearedAndWaitingForInputAnnouncement(
                sessionTitle: "Build",
                paneDescriptor: "pane 2, web"
            ) == "Session error cleared. Agent waiting for your input in Build, pane 2, web."
        )
    }
}
