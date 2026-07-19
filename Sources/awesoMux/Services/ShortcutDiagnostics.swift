import AppKit
import os

@MainActor
enum ShortcutDiagnostics {
    private static let logger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "ShortcutDiagnostics"
    )

    // Resolved once: `sendEvent` evaluates this on every event, and the
    // enabled state can't meaningfully change mid-process because diagnostics
    // are injected via a process-scoped environment variable before launch.
    // Computing it per call would rebuild the environment dictionary on the
    // hottest path in the app.
    static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["AWESOMUX_SHORTCUT_DIAGNOSTICS"] == "1"
    }()

    static let fileURL: URL? = {
        guard isEnabled else { return nil }

        let url = URL(fileURLWithPath: "/tmp", isDirectory: true).appending(
            path: "awesomux-shortcuts-\(ProcessInfo.processInfo.processIdentifier).jsonl"
        )
        do {
            try Data().write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return url
        } catch {
            logger.error("shortcut-diagnostics file setup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    static func logSendEvent(_ event: NSEvent) {
        guard event.type == .keyDown, isEnabled else { return }

        // `chars` is the user's literal typed character. In a terminal app that
        // can be a password or key, so it's redacted in shipped logs and never
        // written to the opt-in flight recorder.
        logger.info(
            """
            shortcut-diagnostics stage=sendEvent \
            keyCode=\(event.keyCode, privacy: .public) \
            modifiers=\(event.modifierFlags.rawValue, privacy: .public) \
            chars=\(event.charactersIgnoringModifiers ?? "", privacy: .private)
            """
        )

        append([
            "stage": "sendEvent",
            "keyCode": Int(event.keyCode),
            "modifiers": event.modifierFlags.rawValue,
            "normalizedModifiers": FloatingPanelEventPolicy.normalizedModifiers(event.modifierFlags).rawValue,
            "isRepeat": event.isARepeat,
            "eventWindow": windowRecord(event.window),
            "keyWindow": windowRecord(NSApp.keyWindow),
            "mainWindow": windowRecord(NSApp.mainWindow),
            "firstResponderClass": responderClass(NSApp.keyWindow?.firstResponder),
            "firstResponderWindow": windowRecord(responderWindow(NSApp.keyWindow?.firstResponder)),
            "eventWindowChildren": event.window?.childWindows?.map { windowRecord($0) } ?? [],
            "keyWindowChildren": NSApp.keyWindow?.childWindows?.map { windowRecord($0) } ?? [],
            "terminalPanels": NSApp.windows.compactMap { window in
                window is TerminalPanelWindow ? windowRecord(window) : nil
            },
        ])
    }

    static func logMatcher(event: NSEvent, matched: Bool) {
        guard event.type == .keyDown, isEnabled else { return }

        logger.info(
            """
            shortcut-diagnostics stage=matcher \
            matched=\(matched, privacy: .public) \
            keyCode=\(event.keyCode, privacy: .public) \
            modifiers=\(event.modifierFlags.rawValue, privacy: .public) \
            chars=\(event.charactersIgnoringModifiers ?? "", privacy: .private) \
            repeat=\(event.isARepeat, privacy: .public)
            """
        )

        append([
            "stage": "matcher",
            "matched": matched,
            "keyCode": Int(event.keyCode),
            "modifiers": event.modifierFlags.rawValue,
            "normalizedModifiers": FloatingPanelEventPolicy.normalizedModifiers(event.modifierFlags).rawValue,
            "isRepeat": event.isARepeat,
        ])
    }

    static func log(_ message: String) {
        guard isEnabled else { return }

        logger.info("shortcut-diagnostics \(message, privacy: .public)")
        append([
            "stage": "route",
            "message": message,
        ])
    }

    private static func append(_ values: [String: Any]) {
        guard let fileURL else { return }

        var record = values
        record["timestamp"] = Date().timeIntervalSince1970
        record["pid"] = ProcessInfo.processInfo.processIdentifier

        do {
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(0x0A)
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            logger.error("shortcut-diagnostics file append failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func windowRecord(_ window: NSWindow?) -> Any {
        guard let window else { return NSNull() }

        return [
            "class": NSStringFromClass(type(of: window)),
            "isKey": window.isKeyWindow,
            "isMain": window.isMainWindow,
            "number": window.windowNumber,
            "parentNumber": window.parent.map { $0.windowNumber as Any } ?? NSNull(),
        ] as [String: Any]
    }

    private static func responderClass(_ responder: NSResponder?) -> Any {
        guard let responder else { return NSNull() }
        return NSStringFromClass(type(of: responder))
    }

    private static func responderWindow(_ responder: NSResponder?) -> NSWindow? {
        switch responder {
        case let view as NSView:
            view.window
        case let window as NSWindow:
            window
        case let controller as NSViewController:
            controller.viewIfLoaded?.window
        default:
            nil
        }
    }
}
