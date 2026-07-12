import SwiftUI
import Testing
@testable import DesignSystem

@Suite("AwFont")
struct AwFontTests {
    // These are NO-TYPO GUARDS, not Dynamic Type behavior tests.
    //
    // They assert that each token is constructed from the expected
    // `.system(textStyle:design:)` (and `.weight(_:)` where applicable)
    // — i.e. that we wrote what we intended to write. They do NOT prove
    // the resulting `Font` actually responds to `dynamicTypeSize` at
    // render time; that is a SwiftUI runtime contract verified by the
    // `#Preview` blocks in `AwFont.swift` and by Accessibility Inspector
    // on the running app.
    //
    // SwiftUI `Font` is `Hashable` and equality is structural — two
    // identical `.system(...)` expressions evaluated in the same scope
    // compare equal. If a future SwiftUI release changes that, these
    // tests should fail loudly so the previews / Inspector path gets a
    // fresh manual check.
    //
    // The only fixed-size case is `mono(.terminal)`; everything else
    // anchors to a text style instead of a fixed point size.

    // MARK: - Mono Token Mapping

    @Test("mono.body anchors to .body with monospaced design")
    func monoBody() {
        #expect(AwFont.mono(.body) == .system(.body, design: .monospaced))
    }

    @Test("mono.meta anchors to .subheadline with monospaced design")
    func monoMeta() {
        #expect(AwFont.mono(.meta) == .system(.subheadline, design: .monospaced))
    }

    @Test("mono.kicker anchors to .footnote monospaced bold")
    func monoKicker() {
        #expect(AwFont.mono(.kicker) == .system(.footnote, design: .monospaced).weight(.bold))
    }

    @Test("mono.pill anchors to .footnote monospaced medium")
    func monoPill() {
        #expect(AwFont.mono(.pill) == .system(.footnote, design: .monospaced).weight(.medium))
    }

    @Test("mono.kbd anchors to .footnote monospaced medium")
    func monoKbd() {
        #expect(AwFont.mono(.kbd) == .system(.footnote, design: .monospaced).weight(.medium))
    }

    @Test("mono.terminal stays fixed at 13pt for libghostty column alignment")
    func monoTerminalIsFixed() {
        #expect(AwFont.mono(.terminal) == .system(size: 13, design: .monospaced))
    }

    @Test("mono.terminal is distinct from mono.body so the carve-out is real")
    func monoTerminalDiffersFromBody() {
        #expect(AwFont.mono(.terminal) != AwFont.mono(.body))
    }

    // MARK: - UI Token Mapping

    @Test("ui.body anchors to .body")
    func uiBody() {
        #expect(AwFont.ui(.body) == .system(.body))
    }

    @Test("ui.meta anchors to .subheadline")
    func uiMeta() {
        #expect(AwFont.ui(.meta) == .system(.subheadline))
    }

    @Test("ui.label anchors to .callout medium")
    func uiLabel() {
        #expect(AwFont.ui(.label) == .system(.callout).weight(.medium))
    }

    @Test("ui.title anchors to .title3 semibold")
    func uiTitle() {
        #expect(AwFont.ui(.title) == .system(.title3).weight(.semibold))
    }

    @Test("ui.sectionHead anchors to .title2 semibold")
    func uiSectionHead() {
        #expect(AwFont.ui(.sectionHead) == .system(.title2).weight(.semibold))
    }

    @Test("ui.display anchors to .largeTitle semibold")
    func uiDisplay() {
        #expect(AwFont.ui(.display) == .system(.largeTitle).weight(.semibold))
    }

    // MARK: - Cross-Token Inequality Guards

    // Cross-token inequality guards. These catch the failure mode where a
    // refactor accidentally collapses two weights or two text styles into
    // each other — equality on each token still passes against its own
    // expected expression, but the tokens stop being distinguishable.

    @Test("mono.kicker (bold) is distinct from mono.pill (medium) despite same text style")
    func monoKickerIsDistinctFromPill() {
        #expect(AwFont.mono(.kicker) != AwFont.mono(.pill))
    }

    @Test("mono.kicker is distinct from a hypothetical semibold variant")
    func monoKickerWeightLockIn() {
        #expect(AwFont.mono(.kicker) != .system(.footnote, design: .monospaced).weight(.semibold))
    }

    @Test("ui.title and ui.sectionHead use different text styles even though both are semibold")
    func uiTitleIsDistinctFromSectionHead() {
        #expect(AwFont.ui(.title) != AwFont.ui(.sectionHead))
    }

    @Test("ui.label weight is locked at medium, not regular or semibold")
    func uiLabelWeightLockIn() {
        #expect(AwFont.ui(.label) != .system(.callout))
        #expect(AwFont.ui(.label) != .system(.callout).weight(.semibold))
    }

    // MARK: - Scaled specs (INT-237)

    @Test("terminal spec is the only fixed carve-out")
    func onlyTerminalIsFixed() {
        #expect(AwFont.spec(.terminal).isFixed)
        for kind in [AwFont.Mono.body, .meta, .kicker, .pill, .kbd] {
            #expect(!AwFont.spec(kind).isFixed)
        }
        for kind in [AwFont.UI.body, .meta, .label, .title, .sectionHead, .display] {
            #expect(!AwFont.spec(kind).isFixed)
        }
    }

    @Test("mono specs carry monospaced design; ui specs default design")
    func specDesigns() {
        #expect(AwFont.spec(AwFont.Mono.body).design == .monospaced)
        #expect(AwFont.spec(AwFont.UI.body).design == .default)
    }

    @Test("spec weights match the plain-token weights")
    func specWeights() {
        #expect(AwFont.spec(AwFont.UI.label).weight == .medium)
        #expect(AwFont.spec(AwFont.UI.title).weight == .semibold)
        #expect(AwFont.spec(AwFont.Mono.kicker).weight == .bold)
        #expect(AwFont.spec(AwFont.UI.body).weight == nil)
    }
}

@Suite("AwTextScale")
struct AwTextScaleTests {
    @Test("clamp keeps in-range values")
    func clampInRange() {
        #expect(AwTextScale.clamp(1.0) == 1.0)
        #expect(AwTextScale.clamp(1.2) == 1.2)
    }

    @Test("clamp bounds out-of-range and non-finite values")
    func clampBounds() {
        #expect(AwTextScale.clamp(5.0) == AwTextScale.range.upperBound)
        #expect(AwTextScale.clamp(0.1) == AwTextScale.range.lowerBound)
        #expect(AwTextScale.clamp(.nan) == AwTextScale.defaultValue)
    }

    @Test("default factor is 1.0 (parity with the unscaled tokens)")
    func defaultIsOne() {
        #expect(AwTextScale.defaultValue == 1.0)
        #expect(AwTextScale.range.contains(AwTextScale.defaultValue))
    }
}

@Suite("AwFont scale-1.0 parity")
@MainActor
struct AwFontScaleParityTests {
    // Guards finding INT-237#6: the `FontSpec` base sizes must match the macOS
    // text-style defaults so that at scale 1.0 the `awFont` path renders at
    // parity with the plain `.font(AwFont.ui/mono(...))` tokens. If a future OS
    // changes a text-style's default point size, this fails loudly rather than
    // letting the two paths silently desync.
    private func platformSize(_ style: Font.TextStyle) -> CGFloat {
        let nsStyle: NSFont.TextStyle = switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        case .body: .body
        @unknown default: .body
        }
        return NSFont.preferredFont(forTextStyle: nsStyle).pointSize
    }

    @Test("ui spec base sizes match their text-style platform defaults")
    func uiSpecsMatchPlatform() {
        for kind in [AwFont.UI.body, .meta, .label, .title, .sectionHead, .display] {
            let spec = AwFont.spec(kind)
            #expect(
                spec.baseSize == platformSize(spec.relativeTo),
                "UI \(kind) base \(spec.baseSize) != platform \(platformSize(spec.relativeTo)) for \(spec.relativeTo)"
            )
        }
    }

    @Test("mono spec base sizes match their text-style platform defaults")
    func monoSpecsMatchPlatform() {
        for kind in [AwFont.Mono.body, .meta, .kicker, .pill, .kbd, .terminal] {
            let spec = AwFont.spec(kind)
            #expect(
                spec.baseSize == platformSize(spec.relativeTo),
                "Mono \(kind) base \(spec.baseSize) != platform \(platformSize(spec.relativeTo)) for \(spec.relativeTo)"
            )
        }
    }
}

@Suite("AwUIFontResolver")
struct AwUIFontResolverTests {
    /// A canonicalizer that spells everything Title-Case-Exact regardless of
    /// input case — lets tests assert the resolver stores the closure's catalog
    /// spelling, not the raw config string.
    private let canonicalizesHelvetica: (String) -> String? = { raw in
        raw.caseInsensitiveCompare("helvetica neue") == .orderedSame ? "Helvetica Neue" : nil
    }

    @Test("\"system\" resolves to the system font without consulting the probe")
    func systemFallsBack() {
        // The probe would return a family — proving it isn't consulted.
        #expect(AwUIFontResolver(rawFamily: "system") { _ in "Helvetica Neue" }.family == nil)
        #expect(AwUIFontResolver(rawFamily: "System") { _ in "Helvetica Neue" }.family == nil)
    }

    @Test("empty or whitespace family resolves to the system font")
    func blankFallsBack() {
        #expect(AwUIFontResolver(rawFamily: "") { _ in "Helvetica Neue" }.family == nil)
        #expect(AwUIFontResolver(rawFamily: "   ") { _ in "Helvetica Neue" }.family == nil)
    }

    @Test("a family the probe rejects falls back safely to the system font")
    func rejectedFamilyFallsBack() {
        let resolver = AwUIFontResolver(rawFamily: "Totally Not Installed") { _ in nil }
        #expect(resolver.family == nil)
    }

    @Test("a differently-cased raw family stores the catalog spelling")
    func caseInsensitiveCanonicalization() {
        let resolver = AwUIFontResolver(rawFamily: "  helvetica NEUE  ", canonicalFamily: canonicalizesHelvetica)
        #expect(resolver.family == "Helvetica Neue")
    }

    // MARK: - face(atSize:spec:) — the live rendering path behind `awFont`

    @Test("system default renders the system face at the given size")
    func faceSystemDefault() {
        let resolver = AwUIFontResolver()
        let spec = AwFont.spec(AwFont.UI.body)
        #expect(resolver.face(atSize: 15, spec: spec) == .system(size: 15, design: .default))
    }

    @Test("a custom family renders that family for proportional ui specs")
    func faceCustomProportional() {
        let resolver = AwUIFontResolver(family: "Helvetica Neue")
        let spec = AwFont.spec(AwFont.UI.body)
        #expect(resolver.face(atSize: 15, spec: spec) == .custom("Helvetica Neue", fixedSize: 15))
    }

    @Test("mono specs ignore the custom family and stay system monospaced")
    func faceMonoIgnoresCustomFamily() {
        // The design carve-out: pills/kbd/terminal alignment must not shift
        // with a proportional UI family.
        let resolver = AwUIFontResolver(family: "Helvetica Neue")
        let spec = AwFont.spec(AwFont.Mono.body)
        #expect(resolver.face(atSize: 13, spec: spec) == .system(size: 13, design: .monospaced))
    }
}
