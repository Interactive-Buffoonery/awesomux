import AwesoMuxBridgeProtocol
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

    @Test(arguments: [
        ("ed@webserver: ~/app", "webserver"), ("ed@webserver", "webserver"),
        ("root@db-01: /var/log", "db-01"), ("ed@webserver:22", "webserver"),
        ("ed@192.168.1.5: ~", "192.168.1.5"), ("ed@[2001:db8::1]: ~", "[2001:db8::1]"),
        ("ed@mymac.corp: ~", "mymac.corp"), ("ed@127.example.com: ~", "127.example.com"),
        ("sam@dev_api: ~/svc", "dev_api"), ("ed@webserver: ~/x\r\n", "webserver"),
        ("ed@webserver:~/app", "webserver"),
    ])
    func remoteTitles(title: String, host: String) {
        #expect(detect(title) == .remote(host: host))
    }

    @Test(arguments: ["ed@mymac: ~/app", "ed@mymac.local: ~", "ed@localhost: ~", "ed@127.0.0.1", "ed@[::1]"])
    func localTitles(title: String) {
        #expect(detect(title) == .local)
    }

    @Test(arguments: [
        ("~/projects/awesomux", Self.local), ("starship ❯ build", Self.local), ("", Self.local),
        ("user@example.com — Mail", Self.local), ("vim foo@bar.txt", Self.local),
        ("ed@web\u{202E}evil: ~", Self.local), ("ed@webserver: ~", Set<String>()),
        ("ed@-bad-: ~", Self.local), ("status line\ned@webserver: ~", Self.local),
        ("ed@\(String(repeating: "a", count: 500)): ~", Self.local),
        ("ed@web%20server: ~", Self.local), ("ssh://ed@webserver:22", Self.local),
        ("ed@example.com: Inbox (3)", Self.local),
    ])
    func indeterminateTitles(title: String, localNames: Set<String>) {
        #expect(RemoteSessionDetector.detect(title: title, localNames: localNames) == .indeterminate)
    }
}

// MARK: - Store transitions (stickiness)

@MainActor
@Suite("SessionStore remote-session tracking")
struct SessionStoreRemoteSessionTests {
    private func makeStore(
        workingDirectory: String = "/Users/me/project"
    ) -> (SessionStore, TerminalSession.ID, TerminalPane.ID) {
        let session = TerminalSession(
            title: "shell",
            workingDirectory: workingDirectory,
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

    @Test(arguments: [
        ("/Users/me/Ｄｅｖｅｌｏｐｍｅｎｔ＠a8c", "Development@a8c", nil as String?),
        ("/Users/me/Development@a8c", "Development@a8c: ~", "a8c"),
    ])
    func directoryTitleDistinguishesPrompt(directory: String, title: String, host: String?) {
        let (store, sid, pid) = makeStore(workingDirectory: directory)
        store.updatePane(sessionID: sid, paneID: pid, title: title)
        #expect(remoteHost(store, pid) == host)
        #expect(store.index.remotePaneIDs == (host == nil ? [] : Set([pid])))
        #expect(store.selectedSession?.layout.pane(id: pid)?.title == title)
        if host == nil {
            store.updatePane(sessionID: sid, paneID: pid, title: "✳ Claude Code")
            #expect(remoteHost(store, pid) == nil)
        }
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

    // A real, existing directory so the pwd survives WorkingDirectoryValidator and
    // is actually applied (only an applied cwd clears remote — see B3).
    private static let validLocalDir = NSTemporaryDirectory()

    @Test("an OSC 7 pwd update clears remote (authoritative local signal)")
    func pwdClearsRemote() {
        let (store, sid, pid) = makeStore()
        store.updatePane(sessionID: sid, paneID: pid, title: "ed@webserver: ~/app")
        #expect(remoteHost(store, pid) == "webserver")
        #expect(store.index.remotePaneIDs == Set([pid]))

        // Failure modes: remote paths must not need local existence, overwrite the
        // local cwd, accept another host, or land on a repointed terminal.
        let terminalID = store.session(id: sid)!.layout.pane(id: pid)!.terminalSessionID
        let localDirectory = store.session(id: sid)!.layout.pane(id: pid)!.workingDirectory
        store.updateObservedRemoteWorkingDirectory(
            sessionID: sid, paneID: pid, terminalSessionID: terminalID,
            expectedHost: "webserver", reportedDirectory: "file://webserver/srv/remote-only"
        )
        #expect(remoteWorkingDirectory(store, pid) == "/srv/remote-only")
        #expect(store.session(id: sid)?.layout.pane(id: pid)?.workingDirectory == localDirectory)
        store.updateObservedRemoteWorkingDirectory(
            sessionID: sid, paneID: pid, terminalSessionID: terminalID,
            expectedHost: "webserver", reportedDirectory: "file://another/srv/wrong"
        )
        #expect(remoteWorkingDirectory(store, pid) == "/srv/remote-only")
        store.updateObservedRemoteWorkingDirectory(
            sessionID: sid, paneID: pid, terminalSessionID: .generate(),
            expectedHost: "webserver", reportedDirectory: "file://webserver/srv/wrong"
        )
        #expect(remoteWorkingDirectory(store, pid) == "/srv/remote-only")
        store.updateObservedRemoteWorkingDirectory(
            sessionID: sid, paneID: pid, terminalSessionID: terminalID,
            expectedHost: "webserver", reportedDirectory: "file://WEBSERVER/srv/second%20directory"
        )
        #expect(remoteWorkingDirectory(store, pid) == "/srv/second directory")

        store.updatePane(sessionID: sid, paneID: pid, title: "ed@otherhost: ~")
        #expect(remoteWorkingDirectory(store, pid) == nil)
        store.updateObservedRemoteWorkingDirectory(
            sessionID: sid, paneID: pid, terminalSessionID: terminalID,
            expectedHost: "webserver", reportedDirectory: "file://webserver/srv/late"
        )
        #expect(remoteWorkingDirectory(store, pid) == nil)
        store.updateObservedRemoteWorkingDirectory(
            sessionID: sid, paneID: pid, terminalSessionID: terminalID,
            expectedHost: "otherhost", reportedDirectory: "file://otherhost/srv/current"
        )
        #expect(remoteWorkingDirectory(store, pid) == "/srv/current")

        store.updatePane(sessionID: sid, paneID: pid, workingDirectory: Self.validLocalDir)
        #expect(remoteHost(store, pid) == nil)
        #expect(remoteWorkingDirectory(store, pid) == nil)
        #expect(remoteConnectionHealth(store, pid) == .active)
        #expect(store.index.remotePaneIDs.isEmpty)
    }

    @Test(arguments: ["command", "localTitle", "rejectedPwd"])
    func remoteHostStaysUntilValidatedLocalPwd(transition: String) {
        let (store, sid, pid) = makeStore()
        store.updatePane(sessionID: sid, paneID: pid, title: "ed@webserver: ~/app")
        switch transition {
        case "command": store.updatePane(sessionID: sid, paneID: pid, title: "make")
        case "localTitle": store.updatePane(sessionID: sid, paneID: pid, title: "ed@mymac: ~/local")
        default: store.updatePane(sessionID: sid, paneID: pid, workingDirectory: "/this/does/not/exist-\(UUID().uuidString)")
        }
        #expect(remoteHost(store, pid) == "webserver")
        #expect(store.index.remotePaneIDs == Set([pid]))
        if transition == "localTitle" {
            store.updatePane(sessionID: sid, paneID: pid, workingDirectory: Self.validLocalDir)
            #expect(remoteHost(store, pid) == nil)
        }
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
            hasObservedPendingRemoteSSHProcess: true,
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
        #expect(!json.contains("hasObservedPendingRemoteSSHProcess"))
        #expect(!json.contains("remoteConnectionHealth"))
        #expect(!json.contains("remoteConnectivityEpoch"))
        #expect(!json.contains("remoteWorkingDirectory"))
        #expect(!json.contains("possiblyStale"))

        let restored = try JSONDecoder().decode(TerminalPane.self, from: data)
        #expect(restored.remoteHost == nil)
        #expect(restored.remoteSSHTarget == nil)
        #expect(!restored.hasConsumedManagedSSHWorkspaceOffer)
        #expect(restored.pendingRemoteSSHTarget == nil)
        #expect(!restored.hasObservedPendingRemoteSSHProcess)
        #expect(restored.remoteConnectionHealth == .active)
        #expect(restored.remoteConnectivityEpoch != pane.remoteConnectivityEpoch)
        #expect(restored.remoteWorkingDirectory == nil)
        #expect(restored.title == pane.title)
        #expect(restored.workingDirectory == pane.workingDirectory)
    }
}
