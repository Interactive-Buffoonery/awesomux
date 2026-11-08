import AppKit
import DesignSystem
import SwiftUI

@main
struct MenuStylingFixture: App {
    init() {
        verifyDropdownNavigation()
    }

    var body: some Scene {
        WindowGroup("Menu Styling Fixture") { FixtureView() }
            .defaultSize(width: 620, height: 360)
            .windowResizability(.contentSize)
    }
}

private struct FixtureView: View {
    private static let fontFamilies = NSFontManager.shared.availableFontFamilies.sorted()
    @State private var fontSelection = "System"
    @State private var selection = 599
    @State private var typedInput = ""
    @State private var result = "No action"
    @State private var light = false
    @State private var largeText = false
    @State private var showsSheet = false
    @State private var floating: FloatingSwiftUIPanelWindow?

    private var items: [AppDropdownItem] {
        [.heading("New Agent in")]
            + ["Personal", "Development", "A very long workspace group name that must remain readable"].map { name in
                AppDropdownItem(title: name) { result = name }
            }
            + [AppDropdownItem(title: "New Agent in New Group…") { result = "New group" }]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Button menu styling").awFont(AwFont.UI.title)
            HStack(spacing: 40) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Before: native Menu")
                    Menu {
                        Section("New Agent in") {
                            Button("Personal") { result = "Personal" }
                            Button("Development") { result = "Development" }
                        }
                        Button("New Agent in New Group…") { result = "New group" }
                    } label: {
                        Image(systemName: "plus").frame(width: 32, height: 32)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("After: app dropdown")
                    AppDropdown(items: items, menuTitle: "New Agent menu") {
                        Image(systemName: "plus").frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .accessibilityLabel("New Agent menu")
                }
            }
            HStack {
                AppDropdownPicker(title: "Sample selection", selection: $selection,
                    options: (1...600).map {
                        (value: $0, title: "Choice \($0)" + ($0.isMultiple(of: 3) ? String(repeating: " long wrapping font family", count: 3) : ""))
                    })
                AppDropdown("Disabled choice", items: [
                    AppDropdownItem(title: "Unavailable", isEnabled: false, accessibilityHint: "Not available in this fixture", action: { result = "BUG: disabled action" }),
                    AppDropdownItem(title: "Available") { result = "Available" },
                ])
                AppDropdown("Disabled menu", items: items).disabled(true)
                AppDropdown("Branch prefix", items: [
                    AppDropdownItem(title: "feature/a") { result = "feature/a" },
                    AppDropdownItem(title: "feature/b") { result = "feature/b" },
                ])
            }
            HStack {
                AppDropdownPicker(title: "Empty", selection: $selection, options: [])
                AppDropdown("Fonts", items: [
                    AppDropdownItem(title: "System", id: "System", isSelected: fontSelection == "System") { fontSelection = "System" },
                    .separator,
                ] + Self.fontFamilies.map { family in
                    AppDropdownItem(title: family, id: family, isSelected: fontSelection == family) { fontSelection = family }
                })
                Toggle("Light appearance", isOn: $light)
                Toggle("Large text", isOn: $largeText)
                Button("Floating host") { showFloatingHost() }
                Button("Sheet host") { showsSheet = true }
            }
            .sheet(isPresented: $showsSheet) {
                VStack(spacing: 20) {
                    AppDropdown("Sheet choices", items: items)
                    Button("Close fixture sheet") { showsSheet = false }
                }.padding(30).frame(width: 400, height: 240)
            }
            TextField("Focus return fixture", text: $typedInput)
                .accessibilityLabel("Focus return fixture")
            Text("Result: \(result); selected: \(selection); font: \(fontSelection); input: \(typedInput)")
                .accessibilityIdentifier("fixture-result")
        }
        .awFont(AwFont.UI.label)
        .foregroundStyle(Color.aw.text)
        .padding(30)
        .frame(width: 620, height: 360, alignment: .topLeading)
        .background(Color.aw.surface.chrome)
        .preferredColorScheme(light ? .light : .dark)
        .awTextScale(largeText ? 1.5 : 1)
    }

    private func showFloatingHost() {
        let panel = FloatingSwiftUIPanelWindow(contentRect: NSRect(x: 300, y: 300, width: 500, height: 260), backing: .buffered, defer: false)
        panel.title = "Dropdown floating host"
        panel.onDismiss = { [weak panel] in
            panel?.orderOut(nil)
            result = "Floating host dismissed"
        }
        panel.hostSwiftUIContent(
            VStack(spacing: 20) {
                AppDropdown("Floating choices", items: items)
                Text("The floating host must stay open while its dropdown has focus.")
                Button("Close floating fixture") { [weak panel] in panel?.onDismiss?() }
            }.padding(30).frame(width: 500, height: 260)
                .background(Color.aw.surface.chrome).preferredColorScheme(.dark))
        floating = panel
        result = "Floating host open"
        panel.presentAndFocus()
    }

}

// Keep pure navigation failure checks in the native fixture, outside the unit suite.
private func verifyDropdownNavigation() {
    precondition(AppDropdownNavigation.next(after: nil, forward: true, enabled: [1, 3]) == 1)
    precondition(AppDropdownNavigation.next(after: 1, forward: true, enabled: [1, 3]) == 3)
    precondition(AppDropdownNavigation.next(after: 3, forward: true, enabled: [1, 3]) == 1)
    precondition(AppDropdownNavigation.next(after: 1, forward: false, enabled: [1, 3]) == 3)
    precondition(AppDropdownNavigation.next(after: nil, forward: false, enabled: [1, 3]) == 3)
    precondition(AppDropdownNavigation.next(after: 7, forward: true, enabled: []) == nil)
    precondition(AppDropdownNavigation.next(after: 7, forward: true, enabled: [3]) == 3)
    let titles = ["New Agent in", "Personal", "Development", "Démo", "Disabled"]
    precondition(AppDropdownNavigation.match(prefix: "de", titles: titles, enabled: [1, 2, 3]) == 2)
    precondition(AppDropdownNavigation.match(prefix: "DEMO", titles: titles, enabled: [1, 2, 3]) == 3)
    precondition(AppDropdownNavigation.match(prefix: "disabled", titles: titles, enabled: [1, 2, 3]) == nil)
    precondition(AppDropdownNavigation.match(prefix: "missing", titles: titles, enabled: []) == nil)
    precondition(AppDropdownNavigation.reconcile(current: 1, old: ["a", "b"], new: ["a", "b"], enabled: [0, 1], fallback: 0) == 1)
    precondition(AppDropdownNavigation.reconcile(current: 1, old: ["a", "b"], new: ["b", "a"], enabled: [0, 1], fallback: 1) == 0)
    precondition(AppDropdownNavigation.reconcile(current: 1, old: ["a", "b"], new: ["a"], enabled: [0], fallback: 0) == 0)
    precondition(AppDropdownNavigation.reconcile(current: 1, old: ["a", "b"], new: ["a", "b"], enabled: [0], fallback: 0) == 0)
    precondition(AppDropdownNavigation.reconcile(current: nil, old: ["a"], new: ["a"], enabled: [], fallback: nil) == nil)
}
