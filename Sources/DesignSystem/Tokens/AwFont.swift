import SwiftUI

public enum AwFont {
    public enum Mono {
        case body
        case meta
        case kicker
        case pill
        case kbd
        case terminal
    }

    public enum UI {
        case body
        case meta
        case label
        case title
        case sectionHead
        case display
    }

    // MARK: - Mono

    public static func mono(_ kind: Mono) -> Font {
        switch kind {
        case .body:
            return .system(.body, design: .monospaced)
        case .meta:
            return .system(.subheadline, design: .monospaced)
        case .kicker:
            return .system(.footnote, design: .monospaced).weight(.bold)
        case .pill:
            return .system(.footnote, design: .monospaced).weight(.medium)
        case .kbd:
            return .system(.footnote, design: .monospaced).weight(.medium)
        case .terminal:
            // Reserved fixed-size token for future SwiftUI surfaces that
            // mirror or border the terminal pane. The live libghostty
            // surface owns its font sizing through GhosttyRuntime. If a
            // configurable terminal font maps into SwiftUI chrome later,
            // it must NOT be anchored to a Dynamic Type text style:
            // libghostty grids columns to a measured cell width, so a
            // scaling font would drift the grid. This token holds that
            // contract for chrome that needs to match the terminal.
            return .system(size: 13, design: .monospaced)
        }
    }

    // MARK: - UI

    /// The text-style-anchored system mapping for a UI token. The user's
    /// configured UI font family (INT-367) is applied by the `.awFont(...)`
    /// modifier via `\.awUIFont` — every live chrome call site goes through it,
    /// so this static path deliberately stays plain system.
    public static func ui(_ kind: UI) -> Font {
        switch kind {
        case .body:
            return .system(.body)
        case .meta:
            return .system(.subheadline)
        case .label:
            return .system(.callout).weight(.medium)
        case .title:
            return .system(.title3).weight(.semibold)
        case .sectionHead:
            return .system(.title2).weight(.semibold)
        case .display:
            return .system(.largeTitle).weight(.semibold)
        }
    }

    // MARK: - Scaled point-size specs
    //
    // macOS has no iOS-style Dynamic Type: `Font.system(.body)` reads a fixed
    // point size from `NSFont.preferredFont(forTextStyle:)` and does NOT move
    // when `.dynamicTypeSize(_:)` is set on the environment (INT-237). The
    // `ui`/`mono` tokens above stay text-style-anchored for semantics, but they
    // cannot deliver real user-facing scaling on macOS on their own.
    //
    // `FontSpec` carries what a `@ScaledMetric(relativeTo:)`-driven modifier
    // needs to synthesize a genuinely scaling font: a base point size, the text
    // style to scale relative to (so the growth curve matches the platform), and
    // the design/weight to rebuild the face. `View.awFont(_:)` consumes it.
    public struct FontSpec: Sendable, Equatable {
        public var baseSize: CGFloat
        public var relativeTo: Font.TextStyle
        public var design: Font.Design
        public var weight: Font.Weight?
        /// When true the spec is a fixed carve-out and must never scale — the
        /// `mono(.terminal)` grid-alignment contract (see the `terminal` case).
        public var isFixed: Bool

        public init(
            baseSize: CGFloat,
            relativeTo: Font.TextStyle,
            design: Font.Design = .default,
            weight: Font.Weight? = nil,
            isFixed: Bool = false
        ) {
            self.baseSize = baseSize
            self.relativeTo = relativeTo
            self.design = design
            self.weight = weight
            self.isFixed = isFixed
        }
    }

    // Base sizes mirror macOS's default `NSFont.preferredFont` point sizes for
    // each text style at the standard content size, so at scale 1.0 the scaled
    // path renders at parity with the plain `ui`/`mono` tokens.
    public static func spec(_ kind: UI) -> FontSpec {
        switch kind {
        case .body:
            return FontSpec(baseSize: 13, relativeTo: .body)
        case .meta:
            return FontSpec(baseSize: 11, relativeTo: .subheadline)
        case .label:
            return FontSpec(baseSize: 12, relativeTo: .callout, weight: .medium)
        case .title:
            return FontSpec(baseSize: 15, relativeTo: .title3, weight: .semibold)
        case .sectionHead:
            return FontSpec(baseSize: 17, relativeTo: .title2, weight: .semibold)
        case .display:
            return FontSpec(baseSize: 26, relativeTo: .largeTitle, weight: .semibold)
        }
    }

    public static func spec(_ kind: Mono) -> FontSpec {
        switch kind {
        case .body:
            return FontSpec(baseSize: 13, relativeTo: .body, design: .monospaced)
        case .meta:
            return FontSpec(baseSize: 11, relativeTo: .subheadline, design: .monospaced)
        case .kicker:
            return FontSpec(baseSize: 10, relativeTo: .footnote, design: .monospaced, weight: .bold)
        case .pill:
            return FontSpec(baseSize: 10, relativeTo: .footnote, design: .monospaced, weight: .medium)
        case .kbd:
            return FontSpec(baseSize: 10, relativeTo: .footnote, design: .monospaced, weight: .medium)
        case .terminal:
            // Fixed carve-out: libghostty grids columns to a measured cell
            // width, so a scaling font drifts the grid. See `mono(.terminal)`.
            return FontSpec(baseSize: 13, relativeTo: .body, design: .monospaced, isFixed: true)
        }
    }
}

// MARK: - Text-size scaling

/// The user-facing chrome text-size multiplier (`appearance.ui_text_scale`).
/// macOS has no Dynamic Type slider for app chrome, so awesoMux ships its own.
/// The factor is applied *continuously* (not quantized into `DynamicTypeSize`
/// buckets): every slider step moves the rendered size, so the control's
/// percent readout never lies.
public enum AwTextScale {
    /// Allowed persisted factor range. 1.0 is the shipped default (parity with
    /// the non-scaled tokens); the ceiling stays below the point where fixed
    /// chrome affordances (titlebar, pill capsules) start to clip.
    ///
    /// KEEP IN SYNC with the hand-copied bound in `AppearanceConfig.validate()`.
    /// The config layer (`AwesoMuxConfig`) can't depend on `DesignSystem`, so
    /// the range is duplicated there deliberately; change both together.
    public static let range: ClosedRange<Double> = 0.85...1.35
    public static let defaultValue: Double = 1.0

    public static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

private struct AwTextScaleKey: EnvironmentKey {
    static let defaultValue: Double = AwTextScale.defaultValue
}

public extension EnvironmentValues {
    /// The resolved chrome text-size multiplier. Read by the `awFont` modifier;
    /// defaults to 1.0 so previews and tests render at nominal size.
    var awTextScale: Double {
        get { self[AwTextScaleKey.self] }
        set { self[AwTextScaleKey.self] = newValue }
    }
}

public extension View {
    /// Inject the resolved chrome text-size multiplier into descendant views.
    /// Clamped at consumption in `AwScaledFont`.
    func awTextScale(_ factor: Double) -> some View {
        environment(\.awTextScale, factor)
    }
}

// MARK: - UI font family (INT-367)

/// Resolves the user-configured UI font family (`appearance.ui_font`) into a
/// concrete `Font`, falling back safely to the system font when the family is
/// `"system"`, blank, not installed, or not a proportional face. The raw config
/// value is preserved upstream in `AppearanceConfig`; this type only decides
/// how to render it.
///
/// Only the proportional `ui` tokens honor a custom family. The `mono` tokens
/// stay on the system monospaced face: they align pills/kbd capsules and (for
/// `.terminal`) mirror the libghostty grid, where the terminal's own mono-font
/// setting — not this UI family — is the source of truth.
///
/// Known limitation: the family is probed once per resolver construction (an
/// appearance change). Installing or removing a font mid-session isn't
/// re-probed until the next appearance edit or relaunch — acceptable because
/// font churn while the app runs is rare and self-heals on the next change.
public struct AwUIFontResolver: Equatable, Sendable {
    /// The resolved family in the font catalog's own spelling, or `nil` for the
    /// system font. Blank/"system"/uninstalled/non-proportional raw values all
    /// resolve to `nil` (safe fallback), so this is the *validated, canonical*
    /// family, never the raw config string.
    public let family: String?

    public init(family: String? = nil) {
        self.family = family
    }

    /// Build a resolver from a raw `appearance.ui_font` value. `"system"` and
    /// empty fall back to the system font without probing. Anything else is
    /// resolved through `canonicalFamily`, which must return the catalog's own
    /// spelling for an installed *proportional* family (matching
    /// case-insensitively — `Font.custom`/`NSFontManager` resolve names
    /// case-insensitively, so validation must too) or `nil` to fall back.
    /// Injected so the decision is unit-testable without a live font
    /// environment; production supplies the cached catalog lookup.
    public init(rawFamily: String, canonicalFamily: (String) -> String?) {
        let trimmed = rawFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("system") == .orderedSame {
            self.family = nil
        } else {
            self.family = canonicalFamily(trimmed)
        }
    }

    /// The face for an already-scaled point size (the `awFont` modifier path):
    /// custom family for proportional UI specs, otherwise the system face at the
    /// same size and design. Weight is applied by the caller.
    public func face(atSize size: CGFloat, spec: AwFont.FontSpec) -> Font {
        if spec.design == .default, let family {
            return Font.custom(family, fixedSize: size)
        }
        return Font.system(size: size, design: spec.design)
    }
}

private struct AwUIFontResolverKey: EnvironmentKey {
    static let defaultValue = AwUIFontResolver()
}

/// Main-actor mailbox for SwiftUI trees hosted outside the configured app
/// hierarchy, such as `AwModal`'s standalone `NSHostingController`.
@MainActor
public enum AwUIFontRuntime {
    public static var current = AwUIFontResolver()
}

public extension EnvironmentValues {
    /// The resolved UI font family. Read by the `awFont` modifier so its body
    /// re-evaluates when the family changes. Defaults to the system font so
    /// previews and tests render nominally.
    var awUIFont: AwUIFontResolver {
        get { self[AwUIFontResolverKey.self] }
        set { self[AwUIFontResolverKey.self] = newValue }
    }
}

public extension View {
    /// Inject the resolved UI font family into descendant views.
    func awUIFont(_ resolver: AwUIFontResolver) -> some View {
        environment(\.awUIFont, resolver)
    }
}

// MARK: - Scaled awFont modifier

/// Applies an `AwFont` token as a genuinely scaling font on macOS.
///
/// Unlike `.font(AwFont.ui(.body))`, which is frozen at its text-style point
/// size on macOS, this modifier drives the point size through
/// `@ScaledMetric(relativeTo:)` (so the platform Dynamic Type growth curve
/// still applies) and then multiplies by the continuous `\.awTextScale` factor
/// from the in-app text-size setting. macOS's `Font.system(.body)` ignores
/// `dynamicTypeSize`, so this modifier is what actually resizes chrome text.
/// Fixed specs (`mono(.terminal)`) bypass scaling entirely.
public extension View {
    @ViewBuilder
    func awFont(_ kind: AwFont.UI) -> some View {
        modifier(AwScaledFont(spec: AwFont.spec(kind)))
    }

    @ViewBuilder
    func awFont(_ kind: AwFont.Mono) -> some View {
        let spec = AwFont.spec(kind)
        // Fixed specs (`mono(.terminal)`) never scale — route them straight to
        // `.font` so no `@ScaledMetric` is registered for a size it can't move.
        if spec.isFixed {
            self.font(AwScaledFont.font(atSize: spec.baseSize, spec: spec))
        } else {
            modifier(AwScaledFont(spec: spec))
        }
    }
}

private struct AwScaledFont: ViewModifier {
    let spec: AwFont.FontSpec

    // Read the user factor and UI font family from the environment so the
    // modifier's body re-evaluates when either changes — the same dependency
    // contract `\.awAccent` uses for accent.
    @Environment(\.awTextScale) private var textScale
    @Environment(\.awUIFont) private var uiFont
    @ScaledMetric private var scaledSize: CGFloat

    init(spec: AwFont.FontSpec) {
        self.spec = spec
        _scaledSize = ScaledMetric(
            wrappedValue: spec.baseSize,
            relativeTo: spec.relativeTo
        )
    }

    func body(content: Content) -> some View {
        let size = scaledSize * AwTextScale.clamp(textScale)
        let base = uiFont.face(atSize: size, spec: spec)
        content.font(spec.weight.map { base.weight($0) } ?? base)
    }

    static func font(atSize size: CGFloat, spec: AwFont.FontSpec) -> Font {
        let base = Font.system(size: size, design: spec.design)
        return spec.weight.map { base.weight($0) } ?? base
    }
}

public enum AwSpacing {
    /// Space between an elevated overlay and the control that invoked it.
    public static let overlayGap: CGFloat = 8
    /// Shared bottom chrome row height for the sidebar footer and terminal
    /// Path Bar. Keep these aligned so the window's bottom edge reads as one
    /// continuous status surface across the sidebar/content split. Applied as a
    /// `minHeight` (not a fixed height) at both call sites so the rows grow
    /// together under Dynamic Type instead of clipping their scaling text.
    public static let footerChrome: CGFloat = 38
    /// Fixed carve-out (INT-237 audit decision): the titlebar row abuts the
    /// macOS traffic-light controls, which do not scale with the app's text-size
    /// setting. Growing this row would misalign the window's close/minimize/zoom
    /// buttons against the system's fixed geometry. Inner labels use `awFont` so
    /// their text still scales within the fixed row; if that truncates at the
    /// largest sizes, the full title stays reachable via tooltip / peek card
    /// rather than by growing the row into the traffic lights.
    public static let titlebar: CGFloat = 38
    public static let panelPadding: CGFloat = 18
    public static let sectionGap: CGFloat = 26
    /// Shared minHeight for the sidebar and command-palette search fields.
    /// Applied as minHeight (not height) so both grow under Dynamic Type.
    public static let searchFieldHeight: CGFloat = 30
}

public enum AwRadius {
    public static let chip: CGFloat = 3
    public static let kbd: CGFloat = 4
    public static let pill: CGFloat = 5
    public static let button: CGFloat = 6
    public static let panel: CGFloat = 8
    public static let window: CGFloat = 10
}

public enum AwAnimation {
    public static let pulseNeeds = Animation.easeOut(duration: 1.4).repeatForever(autoreverses: true)
}

// MARK: - Text-scaling previews
//
// These previews exist so reviewers can verify in Xcode Canvas that:
// (1) every `awFont` token scales with the `\.awTextScale` factor, and
// (2) `mono(.terminal)` does NOT scale (the libghostty column-alignment
//     carve-out).
//
// To verify on the running app: Settings → Appearance → Interface text size.
// The slider drives `\.awTextScale`; every `awFont` call site updates live.

#if DEBUG
// The sampler drives the *scaling* path (`.awFont(...)`), NOT the frozen
// `.font(AwFont...)` path — that's the whole point of INT-237. Each preview
// injects a different `\.awTextScale` factor; the tokens must render visibly
// different sizes, and `mono(.terminal)` must stay put.
private struct AwFontTokenSampler: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Group {
                    Text("ui.display").awFont(AwFont.UI.display)
                    Text("ui.sectionHead").awFont(AwFont.UI.sectionHead)
                    Text("ui.title").awFont(AwFont.UI.title)
                    Text("ui.label").awFont(AwFont.UI.label)
                    Text("ui.body").awFont(AwFont.UI.body)
                    Text("ui.meta").awFont(AwFont.UI.meta)
                }
                Divider()
                Group {
                    Text("mono.body").awFont(AwFont.Mono.body)
                    Text("mono.meta").awFont(AwFont.Mono.meta)
                    Text("mono.kicker — UPPERCASE").awFont(AwFont.Mono.kicker)
                    Text("mono.pill").awFont(AwFont.Mono.pill)
                    Text("mono.kbd").awFont(AwFont.Mono.kbd)
                }
                Divider()
                Text("mono.terminal — must NOT scale")
                    .awFont(AwFont.Mono.terminal)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .frame(minWidth: 320, minHeight: 480)
    }
}

#Preview("AwFont — default (100%)") {
    AwFontTokenSampler()
        .awTextScale(1.0)
}

#Preview("AwFont — minimum (85%)") {
    AwFontTokenSampler()
        .awTextScale(AwTextScale.range.lowerBound)
}

#Preview("AwFont — maximum (135%)") {
    AwFontTokenSampler()
        .awTextScale(AwTextScale.range.upperBound)
}

#Preview("AwFont — text-scale sweep") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            ForEach([0.85, 1.0, 1.15, 1.35], id: \.self) { factor in
                VStack(alignment: .leading, spacing: 4) {
                    Text(factor.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    AwFontTokenSampler()
                        .awTextScale(factor)
                        .frame(height: 240)
                }
                Divider()
            }
        }
        .padding()
    }
}
#endif
