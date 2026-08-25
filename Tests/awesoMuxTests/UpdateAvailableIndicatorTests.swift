import AppKit
import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import SwiftUI
import Testing

@testable import awesoMux

@Suite("Update available indicator")
struct UpdateAvailableIndicatorTests {
    @Test("hosted indicator has no semantic control without a scheduled update") @MainActor
    func hostedIndicatorHasNoSemanticControlWithoutScheduledUpdate() throws {
        let fixture = try HostedIndicatorFixture(availableVersion: nil, displayMode: .expanded)
        defer { fixture.window.close() }

        #expect(fixture.buttons.isEmpty)
    }

    @Test("hosted expanded indicator renders a native Menu for the available update") @MainActor
    func hostedExpandedIndicatorRendersNativeMenuForAvailableUpdate() throws {
        let fixture = try HostedIndicatorFixture(availableVersion: "2.0", displayMode: .expanded)
        defer { fixture.window.close() }

        let control = try #require(fixture.buttons.first)
        #expect(fixture.buttons.count == 1)
        #expect(control.title == "Update Available")
        #expect(fixture.fittedSize.height >= 32)
        #expect(UpdateAvailableIndicator.accessibilityLabel(for: "2.0").contains("2.0"))

        // SwiftUIPopupButton does not materialize the SwiftUI Menu's NSMenu
        // until AppKit enters its blocking menu-tracking loop. Verify the
        // controller callbacks on the same real, injected controller instead.
        fixture.controller.checkForUpdates()
        #expect(fixture.checks == 1)
        fixture.controller.skipAvailableUpdate()
        #expect(fixture.controller.availableVersion == nil)
    }

    @Test("hosted collapsed indicator preserves the versioned minimum control") @MainActor
    func hostedCollapsedIndicatorPreservesVersionedMinimumControl() throws {
        let fixture = try HostedIndicatorFixture(availableVersion: "2.0", displayMode: .collapsed)
        defer { fixture.window.close() }

        let control = try #require(fixture.buttons.first)
        #expect(fixture.buttons.count == 1)
        #expect(control.title.isEmpty)
        #expect(fixture.fittedSize.width >= 40)
        #expect(fixture.fittedSize.height >= 40)
        #expect(UpdateAvailableIndicator.accessibilityLabel(for: "2.0").contains("2.0"))
    }

}

@MainActor
private final class HostedIndicatorFixture {
    let counter = Counter()
    let controller: UpdateController
    let window: NSWindow
    let hostingView: NSView
    let fittedSize: CGSize

    var checks: Int { counter.value }
    var buttons: [NSButton] { descendants(of: NSButton.self, in: hostingView) }

    init(availableVersion: String?, displayMode: SidebarWidthMode) throws {
        let fixture = try configuredBundle()
        controller = UpdateController(
            runtimeProfile: .production,
            bundle: fixture.bundle,
            checkForUpdatesAction: { [counter] in counter.value += 1 }
        )
        if let availableVersion {
            controller.handleUpdatePresentation(displayVersion: availableVersion, handledBySparkle: false)
        }
        let rootView = UpdateAvailableIndicator(displayMode: displayMode)
            .environment(controller)
        let sizingHost = NSHostingController(rootView: rootView)
        sizingHost.view.layoutSubtreeIfNeeded()
        fittedSize = sizingHost.sizeThatFits(
            in: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        let hosted = SidebarHostedTestHarness.makeWindow(
            rootView: rootView,
            frame: NSRect(x: 0, y: 0, width: 220, height: 80)
        )
        window = hosted.window
        hostingView = hosted.hostingView
        window.alphaValue = 1
        SidebarHostedTestHarness.settleMainRunLoop()
    }

    private func descendants<ViewType: NSView>(
        of type: ViewType.Type,
        in root: NSView
    ) -> [ViewType] {
        let direct = root as? ViewType
        return root.subviews.flatMap { descendants(of: type, in: $0) } + (direct.map { [$0] } ?? [])
    }
}

@MainActor
private final class Counter {
    var value = 0
}

private func configuredBundle() throws -> UpdateFixture {
    let directory = try TemporaryDirectory(prefix: "awesomux-update-available-indicator")
    let bundleURL = directory.url.appending(path: "UpdateFixture.app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    let info: [String: String] = [
        "CFBundleIdentifier": "com.example.awesomux-tests",
        "SUFeedURL": "https://example.com/appcast.xml",
        "SUPublicEDKey": "public-key",
    ]
    let data = try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .xml,
        options: 0
    )
    try data.write(to: bundleURL.appending(path: "Info.plist"))
    return UpdateFixture(directory: directory, bundle: try #require(Bundle(url: bundleURL)))
}

private final class UpdateFixture {
    let directory: TemporaryDirectory
    let bundle: Bundle

    init(directory: TemporaryDirectory, bundle: Bundle) {
        self.directory = directory
        self.bundle = bundle
    }
}
