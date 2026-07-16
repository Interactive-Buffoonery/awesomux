import Foundation
import Testing

@Suite("Sidebar command delivery architecture")
struct SidebarCommandDeliveryArchitectureTests {
    @Test("sidebar interceptors require a live primary content target")
    func sidebarInterceptorsRequirePrimaryContentTarget() throws {
        let application = try source("Sources/awesoMux/App/AwesoMuxApplication.swift")

        for marker in [
            "SidebarFocusShortcut.matches(event)",
            "SidebarVisibilityToggleShortcut.matches(event)",
            "SidebarWidthToggleShortcut.matches(event)",
        ] {
            let branch = try #require(
                application.split(separator: marker, maxSplits: 1).last?
                    .split(separator: "return", maxSplits: 1).first
            )
            #expect(branch.contains("canHandleSidebarShortcut"))
        }
        #expect(application.contains("awesoMuxPrimaryContentWindow != nil"))
    }

    @Test("menu and request methods share live primary content eligibility")
    func menuAndRequestsSharePrimaryContentEligibility() throws {
        let app = try source("Sources/awesoMux/App/AwesoMuxApp.swift")
        let menu = try #require(
            app.split(separator: "Button(\"Focus Sidebar\"", maxSplits: 1).last?
                .split(separator: "let jumpRows", maxSplits: 1).first
        )
        #expect(menu.contains("sidebarCommandTargetAvailability.isAvailable"))

        for method in [
            "private func requestSidebarFocus()",
            "private func requestSidebarWidthToggle()",
            "private func requestSidebarVisibilityToggle()",
        ] {
            let body = try #require(
                app.split(separator: method, maxSplits: 1).last?
                    .split(separator: "private func", maxSplits: 1).first
            )
            #expect(body.contains("sidebarCommandTargetAvailability.refresh()"))
            #expect(body.contains("sidebarCommandTargetAvailability.isAvailable"))
        }
    }

    @Test("focus and visibility requests survive initial observation and host remount")
    func requestsUseOneAcknowledgedMailboxAndHostReadiness() throws {
        let app = try source("Sources/awesoMux/App/AwesoMuxApp.swift")
        let content = try source("Sources/awesoMux/Views/ContentView.swift")
        let controller = try source("Sources/awesoMux/Views/SidebarSplitController.swift")
        let support = try source("Sources/awesoMux/Views/SidebarSplitSupport.swift")

        #expect(
            content.contains(
                ".onChange(of: sidebarPresentationCommandMailbox.pending, initial: true)"))
        #expect(content.contains("deliverPendingSidebarPresentationCommand()"))
        #expect(!content.contains("pendingSidebarFocusRequestID"))
        #expect(!content.contains("pendingSidebarVisibilityRequestID"))
        #expect(!content.contains("retryPendingPersistentVisibility"))
        #expect(
            content.contains(
                ".onChange(of: splitProxy.commandHostGeneration, initial: true)"))
        #expect(
            content.contains(
                ".onChange(of: splitProxy.usableLayoutGeneration, initial: true)"))
        #expect(content.contains("onSidebarPresentationCommandAcknowledged"))
        #expect(app.contains("sidebarPresentationCommandMailbox"))
        #expect(app.contains("onSidebarPresentationCommandAcknowledged"))
        #expect(controller.contains("proxy.commandHostDidInstall()"))
        #expect(support.contains("private(set) var commandHostGeneration"))
        #expect(support.contains("private(set) var usableLayoutGeneration"))
        #expect(support.contains("SidebarPersistentVisibilityDeliveryResult"))
    }

    @Test("delivery result controls retry, rejection, and successful publication")
    func presentationCompletionBranchesByTypedResult() throws {
        let content = try source("Sources/awesoMux/Views/ContentView.swift")
        let completion = String(
            try #require(
                content.split(
                    separator: "private func deliverPendingSidebarPresentationCommand",
                    maxSplits: 1
                ).last?.split(
                    separator: "private func clearInitialEmptyFocusIfEligible",
                    maxSplits: 1
                ).first
            ))

        let deferred = try #require(
            completion.split(separator: "case .deferredUntilHostReady:", maxSplits: 1).last?
                .split(separator: "case .rejected:", maxSplits: 1).first)
        let rejected = try #require(
            completion.split(separator: "case .rejected:", maxSplits: 1).last?
                .split(separator: "case .applied:", maxSplits: 1).first)
        let applied = try #require(
            completion.split(separator: "case .applied:", maxSplits: 1).last)

        #expect(!deferred.contains("onSidebarPresentationCommandAcknowledged"))
        #expect(rejected.contains("onSidebarPresentationCommandAcknowledged"))
        #expect(!rejected.contains("onSidebarPersistentVisibilityChange"))
        #expect(!rejected.contains("deliveredSidebarFocusRequestID"))
        #expect(
            applied.components(separatedBy: "onSidebarPersistentVisibilityChange").count == 2)
        #expect(
            applied.components(separatedBy: "onSidebarPresentationCommandAcknowledged").count
                == 2)
    }

    @Test("only focus surfaces primary content before command emission")
    func onlyFocusSurfacesPrimaryContent() throws {
        let app = try source("Sources/awesoMux/App/AwesoMuxApp.swift")
        let focus = try methodBody(named: "requestSidebarFocus", in: app)
        let width = try methodBody(named: "requestSidebarWidthToggle", in: app)
        let visibility = try methodBody(named: "requestSidebarVisibilityToggle", in: app)
        let surface = try #require(focus.range(of: "appDelegate.surfacePrimaryWindow()"))
        let emit = try #require(
            focus.range(of: "sidebarPresentationCommandMailbox.requestFocus()"))

        #expect(surface.lowerBound < emit.lowerBound)
        #expect(!width.contains("surfacePrimaryWindow"))
        #expect(!visibility.contains("surfacePrimaryWindow"))
    }

    @Test("main-actor sidebar owners isolate deinitialization")
    func mainActorSidebarOwnersIsolateDeinitialization() throws {
        let controller = try source("Sources/awesoMux/Views/SidebarSplitController.swift")
        let availability = try source("Sources/awesoMux/App/AwesoMuxWindowRole.swift")

        #expect(controller.contains("isolated deinit {\n        settleFinal()"))
        #expect(
            availability.contains(
                "isolated deinit {\n        observations.forEach(notificationCenter.removeObserver)"))
        #expect(!controller.contains("deinit {\n        MainActor.assumeIsolated"))
        #expect(!availability.contains("deinit {\n        let notificationCenter"))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func methodBody(named name: String, in source: String) throws -> Substring {
        try #require(
            source.split(separator: "private func \(name)()", maxSplits: 1).last?
                .split(separator: "private func", maxSplits: 1).first
        )
    }
}
