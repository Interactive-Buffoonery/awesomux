import AppKit
import SwiftUI

@MainActor
@Observable
final class Scenario {
    var needsAttention = false
    var draft = "Draft"
}

struct HarnessView: View {
    let scenario: Scenario

    var body: some View {
        @Bindable var scenario = scenario
        AgentIntegrationDisclosureRow(
            title: "Fixture integration", subtitle: "Status fixture",
            needsAttention: scenario.needsAttention, enabledSetupCount: 0
        ) {
            Text("Status")
        } toggle: {
            Toggle("Enabled", isOn: .constant(true))
        } content: {
            TextField("Editable draft", text: $scenario.draft)
        }
        .padding()
        .frame(width: 620)
    }
}

@main
struct Driver {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        setbuf(stdout, nil)
        app.finishLaunching()
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 620, height: 250),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        func settle() {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let deadline = Date().addingTimeInterval(0.2)
            while Date() < deadline {
                while let event = app.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                    app.sendEvent(event)
                }
                app.updateWindows()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
        // SwiftUI accessibility nodes expose the informal AppKit attributes but
        // do not conform to NSAccessibilityProtocol.
        func elements(_ object: Any) -> [NSObject] {
            guard let element = object as? NSObject else { return [] }
            let children = element.accessibilityAttributeValue(.children) as? [Any] ?? []
            return [element] + children.flatMap { elements($0) }
        }
        func header() -> NSObject {
            guard
                let result = elements(window).first(where: {
                    $0.accessibilityAttributeValue(.role) as? String == "AXButton"
                        && ["Expanded", "Collapsed"].contains($0.accessibilityAttributeValue(.value) as? String ?? "")
                })
            else { fatalError("Missing disclosure button") }
            return result
        }
        func expect(_ expanded: Bool, _ message: String) {
            settle()
            guard header().accessibilityAttributeValue(.value) as? String == (expanded ? "Expanded" : "Collapsed") else {
                fatalError(message)
            }
            let hasEditor = elements(window).contains { $0.accessibilityAttributeValue(.role) as? String == "AXTextField" }
            guard hasEditor == expanded else { fatalError("Content visibility: \(message)") }
            print("PASS: \(message)")
        }
        func mount(attention: Bool) -> Scenario {
            let scenario = Scenario()
            scenario.needsAttention = attention
            window.contentView = NSHostingView(rootView: HarnessView(scenario: scenario))
            settle()
            return scenario
        }
        func pressHeader() {
            header().accessibilityPerformAction(.press)
            settle()
        }

        let initial = mount(attention: true)
        expect(true, "Initial attention opens row")
        guard let editor = elements(window).first(where: { $0.accessibilityAttributeValue(.role) as? String == "AXTextField" }) else {
            fatalError("Missing draft editor")
        }
        editor.accessibilitySetValue(true, forAttribute: .focused)
        settle()
        guard let responder = window.firstResponder as? NSTextView else { fatalError("Editor did not receive focus") }
        responder.insertText(" edited", replacementRange: NSRange(location: responder.string.count, length: 0))
        let editedDraft = initial.draft
        guard editedDraft.contains("edited") else { fatalError("Editing did not update draft") }
        initial.needsAttention = false
        expect(true, "Clearing attention keeps edited row open")
        guard window.firstResponder === responder, initial.draft == editedDraft else {
            fatalError("Clearing attention lost editor focus or draft")
        }
        print("PASS: Clearing attention preserves editor focus and text")

        pressHeader()
        expect(false, "Manual collapse closes row")
        initial.needsAttention = true
        expect(false, "Manual collapse wins over new attention")
        initial.needsAttention = false
        expect(false, "Manual collapse survives cleared attention")
        pressHeader()
        expect(true, "Manual expansion opens row")
        initial.needsAttention = true
        expect(true, "Manual expansion survives new attention")
        initial.needsAttention = false
        expect(true, "Manual expansion survives cleared attention")

        let later = mount(attention: false)
        expect(false, "No initial attention leaves row closed")
        later.needsAttention = true
        expect(true, "Later attention opens untouched row")
        later.needsAttention = false
        expect(true, "Clearing later attention keeps row open")
        print("All native disclosure interaction scenarios passed")
    }
}
