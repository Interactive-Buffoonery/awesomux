#if DEBUG
    import AppKit

    /// Local menu evidence from the running application, without AX projection loss.
    @MainActor
    final class MenuTreeDiagnostics {
        private struct Item: Codable {
            let title: String
            let separator: Bool
            let enabled: Bool
            let hidden: Bool
            let keyEquivalent: String
            let modifiers: UInt
            let state: Int
            let children: [Item]
        }

        private struct Snapshot: Codable {
            let processID: Int32
            let bundleID: String
            let operatingSystem: String
            let source: String
            let items: [Item]
        }

        static func startIfRequested() {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "--menu-e2e-output"),
                arguments.indices.contains(index + 1)
            else { return }
            guard case .development(let identity?) = AppRuntimeProfile.current,
                !identity.isEmpty
            else {
                NSLog("Menu E2E rejected profile: %@", String(describing: AppRuntimeProfile.current))
                return
            }
            NSLog(
                "Menu E2E started bundle=%@ languages=%@ locale=%@",
                Bundle.main.bundleIdentifier ?? "", Locale.preferredLanguages.joined(separator: ","),
                Locale.current.identifier
            )
            let output = URL(fileURLWithPath: arguments[index + 1])
            let capture = MenuTreeDiagnostics(output: output)
            capture.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                MainActor.assumeIsolated {
                    capture.sample()
                }
            }
        }

        private let output: URL
        private var timer: Timer?
        private var previous: Data?
        private var stableSamples = 0
        private var attempts = 0

        private init(output: URL) {
            self.output = output
        }

        private func stop() {
            timer?.invalidate()
            timer = nil
        }

        private func sample() {
            attempts += 1
            if attempts == 1 || attempts == 80 {
                NSLog(
                    "Menu E2E sample=%ld active=%d stable=%ld roots=%@",
                    attempts, NSApp.isActive ? 1 : 0, stableSamples,
                    NSApp.mainMenu?.items.map(\.title).joined(separator: " | ") ?? "(none)"
                )
            }
            guard attempts <= 80 else {
                if let menu = NSApp.mainMenu {
                    do {
                        try encodedSnapshot(in: menu).write(
                            to: output.appendingPathExtension("unready.json"), options: .atomic)
                    } catch {
                        NSLog("Menu E2E unready diagnostic failed: %@", error.localizedDescription)
                    }
                }
                stop()
                return
            }
            guard NSApp.isActive, let menu = NSApp.mainMenu,
                ["File", "View", "Workspace", "Pane"].allSatisfy({ title in
                    menu.items.contains { $0.title == title && $0.submenu != nil }
                })
            else { return }
            do {
                let data = try encodedSnapshot(in: menu)
                stableSamples = data == previous ? stableSamples + 1 : 0
                previous = data
                guard stableSamples >= 3 else { return }
                try data.write(to: output, options: .atomic)
                stop()
            } catch {
                NSLog("Menu E2E serialization failed: %@", error.localizedDescription)
                stop()
            }
        }

        private func encodedSnapshot(in menu: NSMenu) throws -> Data {
            let snapshot = Snapshot(
                processID: ProcessInfo.processInfo.processIdentifier,
                bundleID: Bundle.main.bundleIdentifier ?? "",
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                source: "NSApp.mainMenu",
                items: Self.items(in: menu)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(snapshot)
        }

        private static func items(in menu: NSMenu) -> [Item] {
            // Refresh validation, including disabled commands that still own chords.
            menu.update()
            return menu.items.map { item in
                Item(
                    title: item.title,
                    separator: item.isSeparatorItem,
                    enabled: item.isEnabled,
                    hidden: item.isHidden,
                    keyEquivalent: item.keyEquivalent,
                    modifiers: item.keyEquivalentModifierMask.rawValue,
                    state: item.state.rawValue,
                    children: item.submenu.map { items(in: $0) } ?? []
                )
            }
        }
    }
#endif
