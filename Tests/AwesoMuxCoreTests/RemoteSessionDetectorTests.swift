import Foundation
import Testing
@testable import AwesoMuxCore

// MARK: - Detector

@Suite("Remote session detector")
struct RemoteSessionDetectorTests {
    // Pretend this machine is "mymac" (full + short forms, as LocalHostnames emits).
    private static let local: Set<String> = ["mymac", "mymac.local"]

    private func detect(_ title: String) -> RemoteSessionSignal {
        RemoteSessionDetector.detect(title: title, localNames: Self.local)
    }

    @Test("a foreign user@host prompt with a path is remote")
    func remoteWithPath() {
        #expect(detect("ed@webserver: ~/app") == .remote(host: "webserver"))
    }

    @Test("a foreign user@host with no path is remote")
    func remoteNoPath() {
        #expect(detect("ed@webserver") == .remote(host: "webserver"))
    }

    @Test("the bash default \\u@\\h: \\w form (colon-space) is parsed, not eaten by the host")
    func remoteBashDefault() {
        #expect(detect("root@db-01: /var/log") == .remote(host: "db-01"))
    }

    @Test("a user@host port form keeps the host")
    func remoteWithPort() {
        #expect(detect("ed@webserver:22") == .remote(host: "webserver"))
    }

    @Test("a foreign IPv4 host is remote")
    func remoteIPv4() {
        #expect(detect("ed@192.168.1.5: ~") == .remote(host: "192.168.1.5"))
    }

    @Test("a bracketed IPv6 host is remote")
    func remoteIPv6() {
        #expect(detect("ed@[2001:db8::1]: ~") == .remote(host: "[2001:db8::1]"))
    }

    @Test("our own host (short) is local")
    func localShort() {
        #expect(detect("ed@mymac: ~/app") == .local)
    }

    @Test("our own host (.local fqdn) is local")
    func localFQDN() {
        #expect(detect("ed@mymac.local: ~") == .local)
    }

    @Test("a remote FQDN sharing our short label is remote, not a false clear")
    func remoteFQDNSharingShortLabel() {
        // `mymac.corp` shares the short label `mymac` with our `mymac.local`;
        // reducing it to the short form would wrongly treat it as local.
        #expect(detect("ed@mymac.corp: ~") == .remote(host: "mymac.corp"))
    }

    @Test("localhost and loopback IPs are local")
    func loopback() {
        #expect(detect("ed@localhost: ~") == .local)
        #expect(detect("ed@127.0.0.1") == .local)
        #expect(detect("ed@[::1]") == .local)
    }

    @Test("a DNS host starting with 127. is remote, not loopback")
    func dnsHostStartingWith127() {
        #expect(detect("ed@127.example.com: ~") == .remote(host: "127.example.com"))
    }

    @Test("a title with no user@host is indeterminate")
    func noToken() {
        #expect(detect("~/projects/awesomux") == .indeterminate)
        #expect(detect("starship ❯ build") == .indeterminate)
        #expect(detect("") == .indeterminate)
    }

    @Test("an email-in-prose title is rejected (trailing not prompt-shaped)")
    func emailProse() {
        #expect(detect("user@example.com — Mail") == .indeterminate)
    }

    @Test("a running command with a later @ is not a leading user@host")
    func commandWithAt() {
        // "vim foo@bar" → the leading user token would contain a space → rejected.
        #expect(detect("vim foo@bar.txt") == .indeterminate)
    }

    @Test("a bidi/control byte in the host position can't produce a remote flag")
    func bidiHostRejected() {
        // The host capture stops at the non-ASCII override, leaving non-prompt-shaped
        // trailing → indeterminate, so no polluted host is ever surfaced.
        let signal = detect("ed@web\u{202E}evil: ~")
        #expect(signal != .remote(host: "web\u{202E}evil"))
        #expect(signal == .indeterminate)
    }

    @Test("fails closed: with no local names known, a foreign host is indeterminate")
    func failsClosed() {
        #expect(
            RemoteSessionDetector.detect(title: "ed@webserver: ~", localNames: [])
                == .indeterminate
        )
    }

    @Test("a malformed host (trailing hyphen label) is indeterminate")
    func malformedHost() {
        #expect(detect("ed@-bad-: ~") == .indeterminate)
    }

    @Test("an underscore SSH-alias host is detected as remote")
    func underscoreHost() {
        #expect(detect("sam@dev_api: ~/svc") == .remote(host: "dev_api"))
    }

    @Test("trailing CR/LF doesn't break detection")
    func trailingNewline() {
        #expect(detect("ed@webserver: ~/x\r\n") == .remote(host: "webserver"))
    }

    @Test("a multiline title can't smuggle a user@host past a newline")
    func multilineTitle() {
        #expect(detect("status line\ned@webserver: ~") == .indeterminate)
    }

    @Test("an over-long host label is rejected")
    func overLongHost() {
        let host = String(repeating: "a", count: 500)
        #expect(detect("ed@\(host): ~") == .indeterminate)
    }

    @Test("a percent-encoded host is rejected (not prompt-shaped after the run)")
    func percentHost() {
        #expect(detect("ed@web%20server: ~") == .indeterminate)
    }

    @Test("a ssh:// URL in the title is not a leading user@host (URL-ish user)")
    func sshURLTitle() {
        #expect(detect("ssh://ed@webserver:22") == .indeterminate)
    }

    @Test("an email-subject colon title is rejected (colon suffix isn't a port/path)")
    func emailColonSubject() {
        #expect(detect("ed@example.com: Inbox (3)") == .indeterminate)
    }

    @Test("a host:port form is accepted")
    func hostColonPort() {
        #expect(detect("ed@webserver:22") == .remote(host: "webserver"))
    }

    @Test("a colon-then-path form (no space) is accepted")
    func colonThenPath() {
        #expect(detect("ed@webserver:~/app") == .remote(host: "webserver"))
    }
}

// MARK: - Store transitions (stickiness)

@MainActor
@Suite("SessionStore remote-session tracking")
struct SessionStoreRemoteSessionTests {
    private func makeStore() -> (SessionStore, TerminalSession.ID, TerminalPane.ID) {
        let session = TerminalSession(
            title: "shell",
            workingDirectory: "/Users/me/project",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "g", sessions: [session])],
            selectedSessionID: session.id
        )
        store.localHostnames = ["mymac", "mymac.local"]
        let paneID = session.activePane?.id ?? session.layout.firstPaneID
        return (store, session.id, paneID)
    }

    private func remoteHost(_ store: SessionStore, _ paneID: TerminalPane.ID) -> String? {
        store.selectedSession?.layout.pane(id: paneID)?.remoteHost
    }

    private func remoteWorkingDirectory(_ store: SessionStore, _ paneID: TerminalPane.ID) -> String? {
        store.selectedSession?.layout.pane(id: paneID)?.remoteWorkingDirectory
    }

    private func remoteSSHTarget(_ store: SessionStore, _ paneID: TerminalPane.ID) -> String? {
        store.selectedSession?.layout.pane(id: paneID)?.remoteSSHTarget
    }

    private func remoteConnectionHealth(
        _ store: SessionStore,
        _ paneID: TerminalPane.ID
    ) -> RemoteConnectionHealth? {
        store.selectedSession?.layout.pane(id: paneID)?.remoteConnectionHealth
    }

    @Test("a foreign-host title cannot report a remote working directory")
    func titleSetsRemote() {
        let (store, sid, pid) = makeStore()
        #expect(store.index.remotePaneIDs.isEmpty)

        store.updatePane(sessionID: sid, paneID: pid, title: "ed@webserver: ~/app")
        #expect(remoteHost(store, pid) == "webserver")
        #expect(remoteWorkingDirectory(store, pid) == nil)
        #expect(remoteConnectionHealth(store, pid) == .active)
        #expect(store.index.remotePaneIDs == Set([pid]))
    }

    @Test("submitted ssh target is promoted when the pane becomes remote")
    func submittedSSHTargetPromotesOnRemoteTitle() {
        let (store, sid, pid) = makeStore()

        store.noteSubmittedCommand(sessionID: sid, paneID: pid, command: "ssh devbox")
        store.updatePane(sessionID: sid, paneID: pid, title: "alice@devbox: ~/app")

        #expect(remoteHost(store, pid) == "devbox")
        #expect(remoteSSHTarget(store, pid) == "devbox")
    }

    @Test("dismissing the managed offer preserves the explicit conversion target without reopening")
    func managedWorkspaceOfferDismissalPreservesExplicitConversionTarget() {
        let (store, sid, pid) = makeStore()

        store.noteSubmittedCommand(sessionID: sid, paneID: pid, command: "ssh devbox")
        store.updatePane(sessionID: sid, paneID: pid, title: "alice@devbox: ~/app")

        #expect(store.consumeManagedSSHWorkspaceOffer(sessionID: sid, paneID: pid)?.sshDestination == "devbox")
        #expect(store.consumeManagedSSHWorkspaceOffer(sessionID: sid, paneID: pid) == nil)
        #expect(store.managedSSHConversionTarget(sessionID: sid, paneID: pid)?.sshDestination == "devbox")
        #expect(remoteSSHTarget(store, pid) == "devbox")
    }

    @Test("explicit managed conversion rejects unsafe, stale, inactive, and managed panes")
    func explicitManagedConversionEligibility() throws {
        let safe = TerminalPane(
            title: "ssh",
            workingDirectory: "~",
            remoteHost: "server.example",
            remoteSSHTarget: "deploy@server-alias",
            executionPlan: .local
        )
        let unsafe = TerminalPane(
            title: "unsafe",
            workingDirectory: "~",
            remoteHost: "server.example",
            remoteSSHTarget: "-oProxyCommand=example",
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(safe),
                    second: .pane(unsafe)
                )),
            activePaneID: safe.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "Work", sessions: [session])],
            selectedSessionID: session.id
        )

        #expect(
            store.managedSSHConversionTarget(sessionID: session.id, paneID: safe.id)?.sshDestination
                == "deploy@server-alias"
        )
        #expect(store.managedSSHConversionTarget(sessionID: session.id, paneID: unsafe.id) == nil)

        let unobserved = TerminalPane(
            title: "unobserved",
            workingDirectory: "~",
            remoteSSHTarget: "server-alias",
            executionPlan: .local
        )
        let unobservedSession = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            layout: .pane(unobserved),
            activePaneID: unobserved.id
        )
        let unobservedStore = SessionStore(
            groups: [SessionGroup(name: "Work", sessions: [unobservedSession])],
            selectedSessionID: unobservedSession.id
        )
        #expect(
            unobservedStore.managedSSHConversionTarget(
                sessionID: unobservedSession.id,
                paneID: unobserved.id
            ) == nil
        )

        store.markRemotePanesPossiblyStale()
        #expect(store.managedSSHConversionTarget(sessionID: session.id, paneID: safe.id) == nil)

        let target = try #require(RemoteTarget(parsing: "deploy@server-alias"))
        let managed = TerminalPane(
            id: safe.id,
            title: "managed",
            workingDirectory: "~",
            remoteHost: "server.example",
            remoteSSHTarget: target.sshDestination,
            executionPlan: .ssh(SSHExecution(target: target))
        )
        let managedSession = TerminalSession(
            id: session.id,
            title: "shell",
            workingDirectory: "~",
            layout: .pane(managed),
            activePaneID: managed.id
        )
        let managedStore = SessionStore(
            groups: [SessionGroup(name: "Work", sessions: [managedSession])],
            selectedSessionID: managedSession.id
        )
        #expect(
            managedStore.managedSSHConversionTarget(
                sessionID: managedSession.id,
                paneID: managed.id
            ) == nil
        )
    }

    @Test("ssh commands with extra options do not become managed workspace offers")
    func optionedSSHCommandDoesNotBecomeManagedWorkspaceOffer() {
        let (store, sid, pid) = makeStore()

        store.noteSubmittedCommand(sessionID: sid, paneID: pid, command: "ssh -p 2222 devbox")
        store.updatePane(sessionID: sid, paneID: pid, title: "alice@devbox: ~/app")

        #expect(remoteHost(store, pid) == "devbox")
        #expect(remoteSSHTarget(store, pid) == nil)
    }

    @Test("submitted ssh config alias survives prompt hostname")
    func submittedSSHConfigAliasSurvivesPromptHostname() {
        let (store, sid, pid) = makeStore()

        store.noteSubmittedCommand(sessionID: sid, paneID: pid, command: "ssh my-purple")
        store.updatePane(sessionID: sid, paneID: pid, title: "alice@devbox: ~/app")

        #expect(remoteHost(store, pid) == "devbox")
        #expect(remoteSSHTarget(store, pid) == "my-purple")
    }

    @Test("a failed nested ssh keeps the original explicit conversion target")
    func failedNestedSSHRetainsOriginalTarget() {
        let (store, sid, pid) = makeStore()

        store.noteSubmittedCommand(sessionID: sid, paneID: pid, command: "ssh host-a")
        store.updatePane(sessionID: sid, paneID: pid, title: "alice@host-a: ~")
        #expect(store.consumeManagedSSHWorkspaceOffer(sessionID: sid, paneID: pid)?.sshDestination == "host-a")

        store.noteSubmittedCommand(sessionID: sid, paneID: pid, command: "ssh host-b")
        store.updatePane(sessionID: sid, paneID: pid, title: "alice@host-a: ~")

        #expect(remoteSSHTarget(store, pid) == "host-a")
        #expect(store.consumeManagedSSHWorkspaceOffer(sessionID: sid, paneID: pid) == nil)
        #expect(store.managedSSHConversionTarget(sessionID: sid, paneID: pid)?.sshDestination == "host-a")
    }

    @Test("an indeterminate tool title cannot recover a title-derived remote directory")
    func indeterminateTitleDoesNotRecoverRemoteWorkingDirectory() {
        let (store, sid, pid) = makeStore()
        store.updatePane(sessionID: sid, paneID: pid, title: "ed@webserver: ~/app")

        store.updatePane(sessionID: sid, paneID: pid, title: "codex")

        #expect(remoteHost(store, pid) == "webserver")
        #expect(remoteWorkingDirectory(store, pid) == nil)
    }

    @Test("an SSH pane accepts an explicitly reported remote directory")
    func sshPaneAcceptsExplicitlyReportedRemoteDirectory() throws {
        let target = try #require(RemoteTarget(parsing: "my-purple"))
        let pane = TerminalPane(
            title: "shell",
            workingDirectory: "/Users/me/project",
            executionPlan: .ssh(SSHExecution(target: target))
        )
        let session = TerminalSession(
            title: "shell",
            workingDirectory: pane.workingDirectory,
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "g", sessions: [session])],
            selectedSessionID: session.id
        )

        store.updatePane(
            sessionID: session.id,
            paneID: pane.id,
            workingDirectory: "file://devbox/srv/repo"
        )

        #expect(remoteWorkingDirectory(store, pane.id) == "/srv/repo")
        #expect(store.selectedSession?.layout.pane(id: pane.id)?.workingDirectory == "/Users/me/project")
    }

    // A real, existing directory so the pwd survives WorkingDirectoryValidator and
    // is actually applied (only an applied cwd clears remote — see B3).
    private static let validLocalDir = NSTemporaryDirectory()

    @Test("an OSC 7 pwd update clears remote (authoritative local signal)")
    func pwdClearsRemote() {
        let (store, sid, pid) = makeStore()
        store.updatePane(sessionID: sid, paneID: pid, title: "ed@webserver: ~/app")
        #expect(remoteHost(store, pid) == "webserver")
        #expect(store.index.remotePaneIDs == Set([pid]))

        store.updatePane(sessionID: sid, paneID: pid, workingDirectory: Self.validLocalDir)
        #expect(remoteHost(store, pid) == nil)
        #expect(remoteWorkingDirectory(store, pid) == nil)
        #expect(remoteConnectionHealth(store, pid) == .active)
        #expect(store.index.remotePaneIDs.isEmpty)
    }

    @Test("a fresh remote title clears a stale remote health hint")
    func titleResetsStaleRemoteHealth() {
        let (store, sid, pid) = makeStore()
        store.updatePane(sessionID: sid, paneID: pid, title: "ed@webserver: ~/app")
        store.markRemotePanesPossiblyStale()
        #expect(remoteConnectionHealth(store, pid) == .possiblyStale)

        store.updatePane(sessionID: sid, paneID: pid, title: "ed@webserver: ~/app")
        #expect(remoteHost(store, pid) == "webserver")
        #expect(remoteConnectionHealth(store, pid) == .active)
    }

    @Test("markRemotePanesPossiblyStale only affects remote panes")
    func markRemotePanesPossiblyStaleOnlyAffectsRemotePanes() {
        let remotePane = TerminalPane(
            title: "ed@webserver: ~/app",
            workingDirectory: "/tmp",
            remoteHost: "webserver",
            executionPlan: .local
        )
        let localPane = TerminalPane(
            title: "ed@mymac: ~/local",
            workingDirectory: "/tmp",
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "w",
            workingDirectory: "/tmp",
            agentKind: .shell,
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(remotePane),
                    second: .pane(localPane)
                )),
            activePaneID: remotePane.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "g", sessions: [session])])

        store.markRemotePanesPossiblyStale()

        let layout = store.groups[0].sessions[0].layout
        #expect(layout.pane(id: remotePane.id)?.remoteConnectionHealth == .possiblyStale)
        #expect(layout.pane(id: localPane.id)?.remoteConnectionHealth == .active)
        #expect(layout.pane(id: localPane.id)?.remoteHost == nil)
    }

    @Test("remote stays sticky across an indeterminate (command) title between prompts")
    func stickyAcrossCommandTitle() {
        let (store, sid, pid) = makeStore()
        store.updatePane(sessionID: sid, paneID: pid, title: "ed@webserver: ~/app")
        // The remote shell retitles to the running command — no user@host token.
        store.updatePane(sessionID: sid, paneID: pid, title: "make")
        #expect(remoteHost(store, pid) == "webserver")  // not cleared by churn
    }

    @Test("a local-looking title does NOT clear remote — only a pwd event does")
    func localTitleDoesNotClearRemote() {
        let (store, sid, pid) = makeStore()
        store.updatePane(sessionID: sid, paneID: pid, title: "ed@webserver: ~/app")
        // A local-looking title doesn't refresh the cwd, so it must not resurrect
        // local affordances over a stale path — remote stays sticky.
        store.updatePane(sessionID: sid, paneID: pid, title: "ed@mymac: ~/local")
        #expect(remoteHost(store, pid) == "webserver")
        // The pwd event (fresh, host-validated-local cwd) is what clears it.
        store.updatePane(sessionID: sid, paneID: pid, workingDirectory: Self.validLocalDir)
        #expect(remoteHost(store, pid) == nil)
    }

    @Test("a local session is never marked remote")
    func localStaysLocal() {
        let (store, sid, pid) = makeStore()
        store.updatePane(sessionID: sid, paneID: pid, title: "ed@mymac: ~/project")
        #expect(remoteHost(store, pid) == nil)
    }

    @Test("an empty/blank title update does not resurrect cleared remote state")
    func emptyTitleDoesNotResurrectRemote() {
        let (store, sid, pid) = makeStore()
        store.updatePane(sessionID: sid, paneID: pid, title: "ed@webserver: ~/app")
        store.updatePane(sessionID: sid, paneID: pid, workingDirectory: Self.validLocalDir)
        #expect(remoteHost(store, pid) == nil)
        // A blank title sanitizes to empty → pane.title stays the old remote string;
        // detection must NOT reparse it and re-mark the pane remote.
        store.updatePane(sessionID: sid, paneID: pid, title: "   ")
        #expect(remoteHost(store, pid) == nil)
    }

    @Test("a rejected (invalid) pwd does NOT clear remote")
    func rejectedPwdKeepsRemote() {
        let (store, sid, pid) = makeStore()
        store.updatePane(sessionID: sid, paneID: pid, title: "ed@webserver: ~/app")
        // A non-existent absolute path fails validation, so the cwd isn't applied
        // and remote must stay (clearing on it would re-enable a stale local view).
        store.updatePane(
            sessionID: sid,
            paneID: pid,
            workingDirectory: "/this/does/not/exist-\(UUID().uuidString)"
        )
        #expect(remoteHost(store, pid) == "webserver")
        #expect(store.index.remotePaneIDs == Set([pid]))
    }
}

// MARK: - Persistence exclusion

@Suite("TerminalPane remote runtime persistence")
struct TerminalPaneRemoteHostPersistenceTests {
    @Test("remoteHost and remoteConnectionHealth are excluded from persistence")
    func remoteHostNotPersisted() throws {
        let pane = TerminalPane(
            title: "ed@webserver: ~/app",
            workingDirectory: "/srv/app",
            remoteHost: "webserver",
            remoteSSHTarget: "webserver-alias",
            hasConsumedManagedSSHWorkspaceOffer: true,
            pendingRemoteSSHTarget: "other-webserver-alias",
            remoteConnectionHealth: .possiblyStale,
            remoteWorkingDirectory: "~/app",
            executionPlan: .local
        )
        let data = try JSONEncoder().encode(pane)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("remoteHost"))
        #expect(!json.contains("remoteSSHTarget"))
        #expect(!json.contains("hasConsumedManagedSSHWorkspaceOffer"))
        #expect(!json.contains("pendingRemoteSSHTarget"))
        #expect(!json.contains("remoteConnectionHealth"))
        #expect(!json.contains("remoteWorkingDirectory"))
        #expect(!json.contains("possiblyStale"))

        let restored = try JSONDecoder().decode(TerminalPane.self, from: data)
        #expect(restored.remoteHost == nil)
        #expect(restored.remoteSSHTarget == nil)
        #expect(!restored.hasConsumedManagedSSHWorkspaceOffer)
        #expect(restored.pendingRemoteSSHTarget == nil)
        #expect(restored.remoteConnectionHealth == .active)
        #expect(restored.remoteWorkingDirectory == nil)
        #expect(restored.title == pane.title)
        #expect(restored.workingDirectory == pane.workingDirectory)
    }
}

@Suite("TerminalPane value semantics")
struct TerminalPaneValueSemanticsTests {
    @Test("remote connection health is excluded from equality and hashing")
    func remoteConnectionHealthDoesNotAffectEqualityOrHashing() {
        let id = UUID()
        let activePane = TerminalPane(
            id: id,
            title: "ed@webserver: ~/app",
            workingDirectory: "/srv/app",
            remoteHost: "webserver",
            remoteConnectionHealth: .active,
            executionPlan: .local
        )
        let stalePane = TerminalPane(
            id: id,
            title: "ed@webserver: ~/app",
            workingDirectory: "/srv/app",
            remoteHost: "webserver",
            remoteConnectionHealth: .possiblyStale,
            executionPlan: .local
        )

        #expect(activePane == stalePane)
        #expect(Set([activePane, stalePane]).count == 1)
    }

    @Test("remote host remains part of equality")
    func remoteHostAffectsEquality() {
        let id = UUID()
        let localPane = TerminalPane(
            id: id,
            title: "ed@webserver: ~/app",
            workingDirectory: "/srv/app",
            executionPlan: .local
        )
        let remotePane = TerminalPane(
            id: id,
            title: "ed@webserver: ~/app",
            workingDirectory: "/srv/app",
            remoteHost: "webserver",
            executionPlan: .local
        )

        #expect(localPane != remotePane)
    }
}
