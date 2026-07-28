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
        // Every stale reason gets the same announcement on purpose — the
        // oversize case additionally raises a labelled banner over the
        // retained copy, so specialising here would repeat it.
        for reason in [RemoteMarkdownFailureReason.oversize, .notFound, .connection] {
            #expect(
                TerminalAccessibilityAnnouncer.remoteMarkdownAnnouncement(
                    for: .cached(snapshot, staleReason: reason)
                ).contains("stale"))
        }
        // Per reason: the generated page's heading is not exposed as an AX
        // heading, so this announcement is where a VoiceOver user learns
        // whether retrying is worth another eight-second SSH round trip.
        let announcements = [
            RemoteMarkdownFailureReason.connection, .oversize, .notFound,
        ].map {
            TerminalAccessibilityAnnouncer.remoteMarkdownAnnouncement(
                for: .failureDocument(snapshot, reason: $0))
        }

        #expect(announcements[0].contains("failure document"))
        #expect(announcements[1].contains("too large"))
        #expect(announcements[2].contains("not found"))
        #expect(Set(announcements).count == 3, "each reason needs its own wording: \(announcements)")
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

    @Test("reconnect-started announcement claims only the attempt, never success")
    func remoteReconnectStartedAnnouncementClaimsOnlyTheAttempt() {
        // A remote-owned pane has no attach evidence at spawn time, so this copy
        // must stay in the progressive tense — the confirmed-success wording
        // belongs to `remoteReconnected`, which only an `attached` event earns.
        #expect(
            TerminalAccessibilityAnnouncer.remoteReconnectStartedAnnouncement(
                host: "prod.example",
                paneDescriptor: "pane 2, web"
            ) == "Reconnecting to prod.example in pane 2, web."
        )
        #expect(
            TerminalAccessibilityAnnouncer.remoteReconnectStartedAnnouncement(
                host: "prod.example"
            ) == "Reconnecting to prod.example."
        )
        // A pane moved to a local group has no host to name, and a blank
        // descriptor must not leak an empty "in ." fragment.
        #expect(
            TerminalAccessibilityAnnouncer.remoteReconnectStartedAnnouncement(
                host: nil,
                paneDescriptor: "  "
            ) == "Reconnecting."
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

    /// `paneDescriptor(for:in:)` embeds the pane's raw title, so every
    /// announcement taking a descriptor can be handed an arbitrarily long or
    /// multi-line string. `compactTitle` exists to stop that dominating speech
    /// (INT-668) but the descriptor path bypassed it. Assert the bound on the
    /// shared helper's behaviour via all three announcements that use it, so a
    /// fourth caller cannot reintroduce the gap by forgetting to compact.
    @Test("pane descriptors are length-bounded in every announcement that takes one")
    func paneDescriptorsAreLengthBounded() {
        let longTitle = String(repeating: "x", count: 200)
        let descriptor = "pane 2, \(longTitle)"

        let announcements = [
            TerminalAccessibilityAnnouncer.remoteReconnectStartedAnnouncement(
                host: "alpha", paneDescriptor: descriptor)
        ]

        for announcement in announcements {
            #expect(
                announcement.contains("…"),
                "expected the descriptor to be truncated: \(announcement)"
            )
            #expect(
                !announcement.contains(longTitle),
                "the untruncated title reached the spoken string"
            )
        }
    }

    @Test("multi-line pane descriptors are flattened before speaking")
    func paneDescriptorsAreSingleLine() {
        let announcement =
            TerminalAccessibilityAnnouncer
            .remoteReconnectStartedAnnouncement(
                host: "alpha", paneDescriptor: "pane 2,\nsecond line")

        #expect(!announcement.contains("\n"))
        #expect(announcement.contains("second line"))
    }
}
