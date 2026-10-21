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
        // SwiftUI builds its accessibility tree on demand. Enable it for this fixture only.
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
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
        // SwiftUI nodes implement the accessibility selectors without declaring
        // NSAccessibilityProtocol conformance.
        func attribute(_ element: NSObject, _ name: NSAccessibility.Attribute) -> Any? {
            let selectors: [NSAccessibility.Attribute: String] = [
                .children: "accessibilityChildren", .role: "accessibilityRole", .value: "accessibilityValue",
            ]
            let selector = NSSelectorFromString(selectors[name]!)
            if element.responds(to: selector) {
                return element.perform(selector)?.takeUnretainedValue()
            }
            // AppKit's title-cell proxies still use the informal attributes.
            return element.accessibilityAttributeValue(name)
        }
        func elements(_ object: Any) -> [NSObject] {
            guard let element = object as? NSObject else { return [] }
            let children = attribute(element, .children) as? [Any] ?? []
            return [element] + children.flatMap { elements($0) }
        }
        func header() -> NSObject {
            guard
                let result = elements(window).first(where: {
                    attribute($0, .role) as? String == "AXDisclosureTriangle"
                })
            else { fatalError("Missing disclosure control") }
            return result
        }
        func expect(_ expanded: Bool, _ message: String) {
            settle()
            guard (attribute(header(), .value) as? NSNumber)?.boolValue == expanded else {
                fatalError(message)
            }
            let hasEditor = elements(window).contains { attribute($0, .role) as? String == "AXTextField" }
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
            let button = header()
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard button.responds(to: selector) else { fatalError("Disclosure has no press action") }
            typealias Press = @convention(c) (NSObject, Selector) -> Bool
            let press = unsafeBitCast(button.method(for: selector), to: Press.self)
            guard press(button, selector) else { fatalError("Disclosure press failed") }
            settle()
        }

        let initial = mount(attention: true)
        expect(true, "Initial attention opens row")
        guard let editor = elements(window).first(where: { attribute($0, .role) as? String == "AXTextField" }) else {
            fatalError("Missing draft editor")
        }
        let selector = NSSelectorFromString("setAccessibilityFocused:")
        guard editor.responds(to: selector) else { fatalError("Editor cannot receive focus") }
        typealias Focus = @convention(c) (NSObject, Selector, Bool) -> Void
        let focus = unsafeBitCast(editor.method(for: selector), to: Focus.self)
        focus(editor, selector, true)
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
