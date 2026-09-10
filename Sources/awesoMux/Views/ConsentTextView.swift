import SwiftUI

struct ConsentTextView: View {
    let text: String
    let maximumHeight: CGFloat

    var body: some View {
        ConsentScrollView(maximumHeight: maximumHeight) {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// Consent text keeps its full contents reachable while leaving action buttons visible.
struct ConsentScrollView<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder let content: () -> Content

    @State private var contentHeight: CGFloat = 20
    @State private var contentOffset: CGFloat = 0
    @State private var position = ScrollPosition(y: 0)

    var body: some View {
        ScrollView(.vertical) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    contentHeight = height
                }
        }
        .frame(height: min(contentHeight, maximumHeight))
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            contentOffset = offset
        }
        .focusable()
        .onKeyPress(keys: [.upArrow, .downArrow, .pageUp, .pageDown, .home, .end]) { press in
            guard press.modifiers.intersection([.command, .option, .control]).isEmpty,
                let offset = ConsentScrollNavigation.offset(
                    for: press.key,
                    current: contentOffset,
                    contentHeight: contentHeight,
                    viewportHeight: min(contentHeight, maximumHeight)
                )
            else { return .ignored }
            position.scrollTo(y: offset)
            return .handled
        }
    }
}

enum ConsentScrollNavigation {
    static func offset(
        for key: KeyEquivalent,
        current: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat? {
        let maximum = max(0, contentHeight - viewportHeight)
        let proposed: CGFloat
        switch key {
        case .upArrow: proposed = current - 24
        case .downArrow: proposed = current + 24
        case .pageUp: proposed = current - viewportHeight
        case .pageDown: proposed = current + viewportHeight
        case .home: proposed = 0
        case .end: proposed = maximum
        default: return nil
        }
        return min(maximum, max(0, proposed))
    }
}
