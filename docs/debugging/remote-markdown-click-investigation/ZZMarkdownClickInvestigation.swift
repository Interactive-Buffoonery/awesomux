import AppKit
import AwesoMuxCore
import GhosttyKit
import Testing
@testable import awesoMux

@Suite(.serialized) @MainActor struct ZZMarkdownClickInvestigation {
    @Test(arguments: [true, false]) func nativeViewToSheet(managed: Bool) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let target = RemoteTarget(parsing: "minimighty")!
        let pane = TerminalPane(title: "probe", workingDirectory: "/tmp", remoteHost: managed ? nil : "minimighty", remoteSSHTarget: managed ? nil : "minimighty", executionPlan: managed ? .ssh(.init(target: target)) : .local)
        let session = TerminalSession(title: "probe", workingDirectory: "/tmp", layout: .pane(pane), activePaneID: pane.id)
        let store = SessionStore(groups: [SessionGroup(name: "probe", sessions: [session])], selectedSessionID: session.id)
        let runtime = GhosttyRuntime()
        let view = GhosttySurfaceNSView(runtime: runtime, sessionStore: store, session: session, pane: pane, enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let surface = try #require(runtime.createSurface(attachedTo: view, workingDirectory: "/tmp", environment: [:], command: "/bin/sh -c '/bin/cat /tmp/awesomux-markdown-click-investigation/fixture; /bin/sleep 20'"))
        view.surface = surface
        view.lifecycleState.mouseSurfaceIncarnationID = 1
        ghostty_surface_set_size(surface, 800, 400)
        ghostty_surface_set_focus(surface, true)
        defer { view.disposeNativeSurface() }
        try await Task.sleep(for: .seconds(1))
        runtime.tick()
        ghostty_surface_set_content_scale(surface, 1, 1)
        ghostty_surface_set_size(surface, 800, 400)
        let size = ghostty_surface_size(surface)
        print("APP-GRID \(size) bounds=\(view.bounds)")
        for row in 0..<3 {
            let location = NSPoint(x: Double(size.cell_width_px) * 5.5, y: view.bounds.height - Double(size.cell_height_px) * (Double(row) + 0.5))
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            view.sendMousePosition(event)
            var word = ghostty_text_s()
            if ghostty_surface_quicklook_word(surface, &word) {
                print("APP-WORD \(String(cString: word.text!)) pos=\(view.mousePosition(for: event))")
                ghostty_surface_free_text(surface, &word)
            }
            print("APP-PROBE managed=\(managed) row=\(row) native=\(view.nativeMouseLink.withLock { $0.value } ?? "nil") appProbe=\(view.markdownClick(at: event)?.value ?? "nil")")
            if row == 1 {
                view.mouseDown(with: event)
                let release = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
                view.mouseUp(with: release)
                runtime.tick()
                try await Task.sleep(for: .seconds(0.8))
                print("APP-SHEET managed=\(managed) presented=\(window.attachedSheet != nil) key=\(NSApp.keyWindow === window) main=\(NSApp.mainWindow === window)")
                if window.attachedSheet == nil {
                    Task { await GhosttyRuntime.openURLAction(OpenURLAction("./README.md"), from: view) }
                    try await Task.sleep(for: .milliseconds(200))
                    print("APP-DIRECT presented=\(window.attachedSheet != nil)")
                }
                #expect(window.attachedSheet != nil)
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
