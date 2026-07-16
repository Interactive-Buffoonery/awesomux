import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

@Suite("AwColor")
struct AwColorTests {
    @Test("awDynamic resolves aqua to latte and darkAqua to mocha")
    func awDynamicResolvesAppearanceToCorrectHex() throws {
        let color = NSColor.awDynamic(mocha: "#000000", latte: "#ffffff")

        let lightColor = try #require(color.withAppearance(.aqua))
        let darkColor = try #require(color.withAppearance(.darkAqua))

        #expect(lightColor.sRGBComponents == RGBComponents(red: 1, green: 1, blue: 1))
        #expect(darkColor.sRGBComponents == RGBComponents(red: 0, green: 0, blue: 0))
    }

    @Test("awDynamic helper maps all four appearance matches")
    func awDynamicHelperMapsFourAppearanceMatches() {
        let values = (
            mocha: "#000001",
            latte: "#000002",
            mochaHC: "#000003",
            latteHC: "#000004"
        )

        #expect(NSColor.awDynamicHex(
            for: .accessibilityHighContrastAqua,
            mocha: values.mocha,
            latte: values.latte,
            mochaHC: values.mochaHC,
            latteHC: values.latteHC
        ) == values.latteHC)
        #expect(NSColor.awDynamicHex(
            for: .accessibilityHighContrastDarkAqua,
            mocha: values.mocha,
            latte: values.latte,
            mochaHC: values.mochaHC,
            latteHC: values.latteHC
        ) == values.mochaHC)
        #expect(NSColor.awDynamicHex(
            for: .aqua,
            mocha: values.mocha,
            latte: values.latte,
            mochaHC: values.mochaHC,
            latteHC: values.latteHC
        ) == values.latte)
        #expect(NSColor.awDynamicHex(
            for: .darkAqua,
            mocha: values.mocha,
            latte: values.latte,
            mochaHC: values.mochaHC,
            latteHC: values.latteHC
        ) == values.mocha)
    }

    // Constructed appearances are not a reliable fixed oracle on macOS:
    // `NSAppearance(named: .aqua)` can still carry the host Increase Contrast
    // trait at resolution time. The pure helper above locks the standard
    // `.aqua` / `.darkAqua` mapping; this test locks that the dynamic overload
    // follows AppKit's resolved appearance match.
    @Test("awDynamic four-way overload follows constructable appearance matches")
    func awDynamicFourWayOverloadFollowsConstructableAppearanceMatches() throws {
        let values = (
            mocha: "#010203",
            latte: "#040506",
            mochaHC: "#070809",
            latteHC: "#0a0b0c"
        )
        let color = NSColor.awDynamic(
            mocha: values.mocha,
            latte: values.latte,
            mochaHC: values.mochaHC,
            latteHC: values.latteHC
        )

        let lightColor = try #require(color.withAppearance(.aqua))
        let darkColor = try #require(color.withAppearance(.darkAqua))
        let lightAppearance = try #require(NSAppearance(named: .aqua))
        let darkAppearance = try #require(NSAppearance(named: .darkAqua))
        let candidates: [NSAppearance.Name] = [
            .accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua,
            .aqua,
            .darkAqua,
        ]
        let expectedLightHex = NSColor.awDynamicHex(
            for: lightAppearance.bestMatch(from: candidates),
            mocha: values.mocha,
            latte: values.latte,
            mochaHC: values.mochaHC,
            latteHC: values.latteHC
        )
        let expectedDarkHex = NSColor.awDynamicHex(
            for: darkAppearance.bestMatch(from: candidates),
            mocha: values.mocha,
            latte: values.latte,
            mochaHC: values.mochaHC,
            latteHC: values.latteHC
        )

        #expect(lightColor.sRGBComponents == NSColor.awHex(expectedLightHex).sRGBComponents)
        #expect(darkColor.sRGBComponents == NSColor.awHex(expectedDarkHex).sRGBComponents)
    }

    @Test("awDynamic caches: same 4-hex tuple returns the identical instance")
    func awDynamicCachesSameTupleReturnsIdenticalInstance() {
        // Distinct hex values from every other test in this file so cache
        // population here can't be masked by another test's insert.
        let first = NSColor.awDynamic(
            mocha: "#111111", latte: "#222222", mochaHC: "#333333", latteHC: "#444444"
        )
        let second = NSColor.awDynamic(
            mocha: "#111111", latte: "#222222", mochaHC: "#333333", latteHC: "#444444"
        )

        #expect(first === second)
    }

    @Test("awDynamic caches: a different 4-hex tuple returns a distinct instance")
    func awDynamicCachesDifferentTupleReturnsDistinctInstance() {
        let first = NSColor.awDynamic(
            mocha: "#555555", latte: "#666666", mochaHC: "#777777", latteHC: "#888888"
        )
        let second = NSColor.awDynamic(
            mocha: "#999999", latte: "#aaaaaa", mochaHC: "#bbbbbb", latteHC: "#cccccc"
        )

        #expect(first !== second)
    }

    @Test("awDynamic 2-arg and 4-arg overloads share one cache under equal HC values")
    func awDynamicTwoArgAndFourArgOverloadsShareCache() {
        let viaTwoArg = NSColor.awDynamic(mocha: "#dddddd", latte: "#eeeeee")
        let viaFourArg = NSColor.awDynamic(
            mocha: "#dddddd", latte: "#eeeeee", mochaHC: "#dddddd", latteHC: "#eeeeee"
        )

        #expect(viaTwoArg === viaFourArg)
    }

    @Test("awDynamic caches: differently-cased hex for the same color shares the cache")
    func awDynamicCachesCaseInsensitiveHexSharesInstance() {
        // `awHex` parses hex case-insensitively, so `#AABBCC` and `#aabbcc`
        // resolve to the same visual color — the cache key must normalize
        // case too, or two spellings of one color would silently defeat the
        // `===` identity guarantee this cache exists to provide.
        let lower = NSColor.awDynamic(
            mocha: "#aabbcc", latte: "#ccbbaa", mochaHC: "#112233", latteHC: "#332211"
        )
        let upper = NSColor.awDynamic(
            mocha: "#AABBCC", latte: "#CCBBAA", mochaHC: "#112233", latteHC: "#332211"
        )

        #expect(lower === upper)
    }

    @Test("awDynamic name matches the documented cache-key format")
    func awDynamicNameMatchesDocumentedFormat() {
        let color = NSColor.awDynamic(
            mocha: "#f00f00", latte: "#0f000f", mochaHC: "#00f00f", latteHC: "#f000f0"
        )

        #expect(color.colorNameComponent == "awDynamic-#f00f00-#0f000f-#00f00f-#f000f0")
    }

    @Test("awDynamic name is deterministic regardless of which caller's casing populates the cache first")
    func awDynamicNameStaysLowercaseRegardlessOfFirstCallerCasing() {
        // Uppercase hits the cache first here — if `name` were built from
        // the raw arguments instead of the normalized key, this would
        // capture the uppercase spelling and the lowercase call below would
        // silently inherit it, making `colorNameComponent` depend on call
        // order instead of being a pure function of the color.
        let uppercaseFirst = NSColor.awDynamic(
            mocha: "#A1B2C3", latte: "#C3B2A1", mochaHC: "#111111", latteHC: "#222222"
        )
        let lowercaseSecond = NSColor.awDynamic(
            mocha: "#a1b2c3", latte: "#c3b2a1", mochaHC: "#111111", latteHC: "#222222"
        )

        #expect(uppercaseFirst === lowercaseSecond)
        #expect(uppercaseFirst.colorNameComponent == "awDynamic-#a1b2c3-#c3b2a1-#111111-#222222")
    }

    @Test("awDynamic is safe under concurrent same-key access")
    func awDynamicConcurrentSameKeyAccessReturnsOneSharedInstance() {
        let iterations = 200
        let collected = LockedBox<[NSColor]>([])

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            let color = NSColor.awDynamic(
                mocha: "#123456", latte: "#654321", mochaHC: "#abcdef", latteHC: "#fedcba"
            )
            collected.append(color)
        }

        let results = collected.value
        #expect(results.count == iterations)
        #expect(Set(results.map(ObjectIdentifier.init)).count == 1)
    }

    // Same-key contention (above) only proves the lock serializes repeated
    // reads of one already-populated slot — trivially true under almost any
    // locking scheme, including a broken one that only guards the read. The
    // scenario this cache actually exists for (many SwiftUI views resolving
    // *different* tokens on first render) stresses concurrent writes of
    // distinct keys into the same dictionary, which is where an
    // under-scoped lock (e.g. one that only wraps the read-check, not the
    // insert) would corrupt or crash instead of just serializing.
    @Test("awDynamic is safe under concurrent access with distinct keys")
    func awDynamicConcurrentDistinctKeyAccessDoesNotCorruptCache() {
        let keyCount = 32
        let attemptsPerKey = 8
        let tuples: [(mocha: String, latte: String, mochaHC: String, latteHC: String)] = (0..<keyCount).map { i in
            // 1 fixed leading digit + 5 digits of `i` == 6 hex digits total,
            // matching the `#rrggbb` invariant every real call site relies on.
            let hex = String(format: "%05x", i)
            return (mocha: "#e\(hex)", latte: "#d\(hex)", mochaHC: "#c\(hex)", latteHC: "#b\(hex)")
        }
        let collected = LockedBox<[Int: [NSColor]]>([:])

        DispatchQueue.concurrentPerform(iterations: keyCount * attemptsPerKey) { i in
            let tuple = tuples[i % keyCount]
            let color = NSColor.awDynamic(
                mocha: tuple.mocha, latte: tuple.latte, mochaHC: tuple.mochaHC, latteHC: tuple.latteHC
            )
            collected.append(color, forKey: i % keyCount)
        }

        let results = collected.value
        #expect(results.count == keyCount)
        for (_, colors) in results {
            #expect(colors.count == attemptsPerKey)
            #expect(Set(colors.map(ObjectIdentifier.init)).count == 1)
        }
    }

    @Test("high-contrast palettes keep standard surfaces")
    func highContrastPalettesKeepStandardSurfaces() {
        let colors = AwColors()

        for (keyPath, label) in surfaceTokens() {
            #expect(
                colors.mochaHC[keyPath: keyPath] == colors.mocha[keyPath: keyPath],
                "mochaHC \(label) should match mocha"
            )
            #expect(
                colors.latteHC[keyPath: keyPath] == colors.latte[keyPath: keyPath],
                "latteHC \(label) should match latte"
            )
        }
    }

    @Test("high-contrast palettes bump foreground and accent tokens")
    func highContrastPalettesBumpForegroundAndAccentTokens() {
        let colors = AwColors()

        for (keyPath, label) in foregroundTokens() + accentTokens() {
            #expect(
                colors.mochaHC[keyPath: keyPath] != colors.mocha[keyPath: keyPath],
                "mochaHC \(label) should differ from mocha"
            )
            #expect(
                colors.latteHC[keyPath: keyPath] != colors.latte[keyPath: keyPath],
                "latteHC \(label) should differ from latte"
            )
        }
    }

    @Test("high-contrast text tokens clear AA contrast against same-theme surfaces")
    func highContrastTextTokensClearAAContrast() {
        let colors = AwColors()
        let floor = 4.5

        for (palette, paletteLabel) in [(colors.mochaHC, "mochaHC"), (colors.latteHC, "latteHC")] {
            for (foreground, foregroundLabel) in foregroundTokens() {
                for (surface, surfaceLabel) in surfaceTokens() {
                    let ratio = contrastRatio(
                        NSColor.awHex(palette[keyPath: foreground]),
                        NSColor.awHex(palette[keyPath: surface])
                    )
                    #expect(
                        ratio >= floor,
                        "\(paletteLabel) \(foregroundLabel) on \(surfaceLabel): \(ratio) < \(floor)"
                    )
                }
            }
        }
    }

    @Test("high-contrast accent tokens clear non-text contrast against same-theme surfaces")
    func highContrastAccentTokensClearNonTextContrast() {
        let colors = AwColors()
        let floor = 3.0

        for (palette, paletteLabel) in [(colors.mochaHC, "mochaHC"), (colors.latteHC, "latteHC")] {
            for (accent, accentLabel) in accentTokens() {
                for (surface, surfaceLabel) in surfaceTokens() {
                    let ratio = contrastRatio(
                        NSColor.awHex(palette[keyPath: accent]),
                        NSColor.awHex(palette[keyPath: surface])
                    )
                    #expect(
                        ratio >= floor,
                        "\(paletteLabel) \(accentLabel) on \(surfaceLabel): \(ratio) < \(floor)"
                    )
                }
            }
        }
    }

    // Locks the hierarchy invariant on HC foreground tokens against a
    // re-flattening regression. Stacks of `text` / `text2` / `text3` /
    // `textFaint` across the sidebar, settings, session detail, status
    // dot, and agent tile all assume these six levels stay visually
    // distinct under Increase Contrast.
    @Test("high-contrast foreground tokens remain distinct within each palette")
    func highContrastForegroundTokensRemainDistinctWithinPalette() {
        let colors = AwColors()

        for (palette, paletteLabel) in [(colors.mochaHC, "mochaHC"), (colors.latteHC, "latteHC")] {
            let tokens = foregroundTokens()
            for i in 0..<tokens.count {
                for j in (i + 1)..<tokens.count {
                    let (lhsKey, lhsLabel) = tokens[i]
                    let (rhsKey, rhsLabel) = tokens[j]
                    #expect(
                        palette[keyPath: lhsKey] != palette[keyPath: rhsKey],
                        "\(paletteLabel) \(lhsLabel) and \(rhsLabel) should differ"
                    )
                }
            }
        }
    }

    // Locks the two source-code occurrences of the divider HC hexes — the
    // inline values inside `dividerRest`/`dividerHover` and the values in
    // `dividerRestHC`/`dividerHoverHC` — against drift. Per the existing
    // comment at the top of this file, constructed HC appearances are an
    // unreliable oracle on macOS, so we compare via `awDynamicHex(for:…)`
    // directly. If the values diverge, this test fails.
    @Test("dividerRest/Hover inline HC values match standalone HC tokens")
    func dividerRestAndHoverInlineHCMatchesStandaloneHC() {
        // dividerRest
        let restInline = (mocha: "#6c7086", latte: "#82849a", mochaHC: "#9399b2", latteHC: "#6c6f85")
        let restStandalone = (mocha: "#9399b2", latte: "#6c6f85", mochaHC: "#9399b2", latteHC: "#6c6f85")

        #expect(
            NSColor.awDynamicHex(
                for: .accessibilityHighContrastDarkAqua,
                mocha: restInline.mocha,
                latte: restInline.latte,
                mochaHC: restInline.mochaHC,
                latteHC: restInline.latteHC
            ) == NSColor.awDynamicHex(
                for: .accessibilityHighContrastDarkAqua,
                mocha: restStandalone.mocha,
                latte: restStandalone.latte,
                mochaHC: restStandalone.mochaHC,
                latteHC: restStandalone.latteHC
            ),
            "dividerRest mochaHC drifted from dividerRestHC mochaHC"
        )
        #expect(
            NSColor.awDynamicHex(
                for: .accessibilityHighContrastAqua,
                mocha: restInline.mocha,
                latte: restInline.latte,
                mochaHC: restInline.mochaHC,
                latteHC: restInline.latteHC
            ) == NSColor.awDynamicHex(
                for: .accessibilityHighContrastAqua,
                mocha: restStandalone.mocha,
                latte: restStandalone.latte,
                mochaHC: restStandalone.mochaHC,
                latteHC: restStandalone.latteHC
            ),
            "dividerRest latteHC drifted from dividerRestHC latteHC"
        )

        // dividerHover
        let hoverInline = (mocha: "#7f849c", latte: "#6f7288", mochaHC: "#a6adc8", latteHC: "#5c5f77")
        let hoverStandalone = (mocha: "#a6adc8", latte: "#5c5f77", mochaHC: "#a6adc8", latteHC: "#5c5f77")

        #expect(
            NSColor.awDynamicHex(
                for: .accessibilityHighContrastDarkAqua,
                mocha: hoverInline.mocha,
                latte: hoverInline.latte,
                mochaHC: hoverInline.mochaHC,
                latteHC: hoverInline.latteHC
            ) == NSColor.awDynamicHex(
                for: .accessibilityHighContrastDarkAqua,
                mocha: hoverStandalone.mocha,
                latte: hoverStandalone.latte,
                mochaHC: hoverStandalone.mochaHC,
                latteHC: hoverStandalone.latteHC
            ),
            "dividerHover mochaHC drifted from dividerHoverHC mochaHC"
        )
        #expect(
            NSColor.awDynamicHex(
                for: .accessibilityHighContrastAqua,
                mocha: hoverInline.mocha,
                latte: hoverInline.latte,
                mochaHC: hoverInline.mochaHC,
                latteHC: hoverInline.latteHC
            ) == NSColor.awDynamicHex(
                for: .accessibilityHighContrastAqua,
                mocha: hoverStandalone.mocha,
                latte: hoverStandalone.latte,
                mochaHC: hoverStandalone.mochaHC,
                latteHC: hoverStandalone.latteHC
            ),
            "dividerHover latteHC drifted from dividerHoverHC latteHC"
        )
    }

    // Enforces the *reason* the divider tokens exist (INT-299): each must
    // clear WCAG 1.4.11 non-text contrast against the pane background
    // (`surface.terminal` = `base`) in both themes.
    @Test("divider tokens clear WCAG 1.4.11 contrast against the pane background")
    func dividerTokensClearContrastFloor() {
        // Latte rest keeps 0.5 of headroom above the 3:1 floor. Mocha rest
        // remains at its existing 3.36:1; hover and HC keep their contracts.
        let normalRestFloor = (latte: 3.5, mocha: 3.0)
        let highContrastRestFloor = 3.0
        let activeFloor = 4.0

        // base: mocha #1e1e2e, latte #eff1f5 (AwColor.swift).
        let cases: [(KeyPath<AwColors, Color>, latteFloor: Double, mochaFloor: Double, label: String)] = [
            (
                \.dividerRest,
                latteFloor: normalRestFloor.latte,
                mochaFloor: normalRestFloor.mocha,
                label: "dividerRest"
            ),
            (\.dividerHover, latteFloor: activeFloor, mochaFloor: activeFloor, label: "dividerHover"),
            (
                \.dividerRestHC,
                latteFloor: highContrastRestFloor,
                mochaFloor: highContrastRestFloor,
                label: "dividerRestHC"
            ),
            (\.dividerHoverHC, latteFloor: activeFloor, mochaFloor: activeFloor, label: "dividerHoverHC"),
        ]

        for (token, latteFloor, mochaFloor, label) in cases {
            let divider = NSColor(Color.aw[keyPath: token])
            let background = NSColor(Color.aw.surface.terminal)

            for (appearance, floor) in [
                (NSAppearance.Name.aqua, latteFloor),
                (.darkAqua, mochaFloor),
            ] {
                guard let dividerResolved = divider.withAppearance(appearance),
                      let backgroundResolved = background.withAppearance(appearance) else {
                    Issue.record("\(label): could not resolve color for \(appearance.rawValue)")
                    continue
                }

                let ratio = contrastRatio(dividerResolved, backgroundResolved)
                #expect(
                    ratio >= floor,
                    "\(label) on \(appearance.rawValue): \(ratio) < \(floor)"
                )
            }
        }
    }

    // Locks the INT-490 selected-row border contract: the darkened Latte
    // border hexes were derived (AwColor.swift) to clear >=3.25:1 against
    // `surface0`/`elevated` and >=4.1:1 against `mantle`/`sidebar`. A flat 3:1
    // floor would leave ~0.25-1.1 of slack the design margins don't actually
    // have, so each background asserts its own documented target. Mocha keeps
    // the bright accent and clears both with wide room.
    @Test("workspace tint border tokens clear WCAG 1.4.11 contrast")
    func workspaceTintBorderTokensClearContrastFloor() {
        let backgrounds: [(Color, floor: Double, label: String)] = [
            (Color.aw.surface.elevated, floor: 3.25, label: "elevated"),
            (Color.aw.surface.sidebar, floor: 4.1, label: "sidebar"),
        ]

        for accent in AwTintAccent.allCases {
            let border = NSColor(Color.aw.tintBorder(accent))

            for (backgroundColor, floor, backgroundLabel) in backgrounds {
                let background = NSColor(backgroundColor)

                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    guard let borderResolved = border.withAppearance(appearance),
                          let backgroundResolved = background.withAppearance(appearance) else {
                        Issue.record("\(accent) on \(backgroundLabel): could not resolve color for \(appearance.rawValue)")
                        continue
                    }

                    let ratio = contrastRatio(borderResolved, backgroundResolved)
                    #expect(
                        ratio >= floor,
                        "\(accent) border on \(backgroundLabel) \(appearance.rawValue): \(ratio) < \(floor)"
                    )
                }
            }
        }
    }

    @Test("primary text clears non-text contrast for sidebar icon controls")
    func primaryTextClearsSidebarIconControlContrastFloor() {
        let floor = 3.0
        let foreground = NSColor(Color.aw.text)
        let elevated = NSColor(Color.aw.surface.elevated)
        let hoverOverlay = NSColor(Color.aw.surface.hover)

        for backgroundLabel in ["elevated", "elevated+hover"] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                guard let foregroundResolved = foreground.withAppearance(appearance),
                      let elevatedResolved = elevated.withAppearance(appearance),
                      let hoverResolved = hoverOverlay.withAppearance(appearance) else {
                    Issue.record("primary text on \(backgroundLabel): could not resolve color for \(appearance.rawValue)")
                    continue
                }

                let backgroundResolved = backgroundLabel == "elevated"
                    ? elevatedResolved
                    : hoverResolved.composited(over: elevatedResolved)

                let ratio = contrastRatio(foregroundResolved, backgroundResolved)
                #expect(
                    ratio >= floor,
                    "primary text on \(backgroundLabel) \(appearance.rawValue): \(ratio) < \(floor)"
                )
            }
        }
    }

    @Test("accent-on-chrome wordmark text clears WCAG AA for every accent")
    func accentOnChromeWordmarkTextClearsAAContrastFloor() {
        let colors = AwColors()
        let floor = 4.5
        let backgrounds: [(KeyPath<AwPalette, String>, String)] = [
            (\.mantle, "chrome"),
            (\.crust, "chrome2"),
        ]
        let appearances: [(NSAppearance.Name, AwPalette, String)] = [
            (.aqua, colors.latte, "Latte"),
            (.darkAqua, colors.mocha, "Mocha"),
            (.accessibilityHighContrastAqua, colors.latteHC, "Latte HC"),
            (.accessibilityHighContrastDarkAqua, colors.mochaHC, "Mocha HC"),
        ]

        for accent in AwAccent.allCases {
            let foreground = accent.chromeTextHex()

            for (appearance, palette, appearanceLabel) in appearances {
                let foregroundHex = NSColor.awDynamicHex(
                    for: appearance,
                    mocha: foreground.mocha,
                    latte: foreground.latte,
                    mochaHC: foreground.mochaHC,
                    latteHC: foreground.latteHC
                )

                for (background, backgroundLabel) in backgrounds {
                    let ratio = contrastRatio(
                        NSColor.awHex(foregroundHex),
                        NSColor.awHex(palette[keyPath: background])
                    )
                    #expect(
                        ratio >= floor,
                        "\(accent.rawValue) wordmark on \(backgroundLabel) \(appearanceLabel): \(ratio) < \(floor)"
                    )
                }
            }
        }
    }

    @Test("pane title bands are opaque, distinct, and contrast safe in every appearance")
    func paneTitleBandsMeetAccessibilityContract() throws {
        let appearances: [NSAppearance.Name] = [
            .aqua,
            .darkAqua,
            .accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua,
        ]
        let title = NSColor(Color.aw.text)

        for appearance in appearances {
            let titleResolved = try #require(title.withAppearance(appearance))
            let chromeResolved = try #require(
                NSColor(Color.aw.surface.chrome).withAppearance(appearance)
            )
            var resolvedBands: [RGBComponents] = []

            for accent in AwTintAccent.allCases {
                let band = try #require(
                    NSColor(Color.aw.paneTitleBand(accent)).withAppearance(appearance)
                )
                let hue = try #require(
                    NSColor(Color.aw.tint(accent)).withAppearance(appearance)
                )
                let expectedBand = hue.withAlphaComponent(0.22).composited(over: chromeResolved)
                let closeGlyph = titleResolved.withAlphaComponent(0.85).composited(over: band)
                let actualComponents = band.sRGBComponents
                let expectedComponents = expectedBand.sRGBComponents
                let channelTolerance = 1.0 / 255.0 + 0.0001

                #expect(band.alphaComponent == 1, "\(accent) \(appearance.rawValue) is translucent")
                #expect(abs(actualComponents.red - expectedComponents.red) <= channelTolerance)
                #expect(abs(actualComponents.green - expectedComponents.green) <= channelTolerance)
                #expect(abs(actualComponents.blue - expectedComponents.blue) <= channelTolerance)
                #expect(
                    contrastRatio(titleResolved, band) >= 4.5,
                    "\(accent) title on \(appearance.rawValue) misses WCAG AA"
                )
                #expect(
                    contrastRatio(closeGlyph, band) >= 3,
                    "\(accent) close glyph on \(appearance.rawValue) misses WCAG 1.4.11"
                )
                #expect(!resolvedBands.contains(actualComponents))
                resolvedBands.append(actualComponents)
            }

            #expect(
                resolvedBands.count == AwTintAccent.allCases.count,
                "Pane colors must retain distinct identities in \(appearance.rawValue)"
            )
        }
    }

    // The muted-accent divider replaces the neutral gray, but it must hold the
    // SAME 1.4.11 floor INT-299 set: every accent, at rest and on hover, in both
    // themes, clears 3:1 / 4:1 against the pane background. This is the contract
    // that lets a raw-accent regression (e.g. wiring `Color.aw.accent(_:)`
    // straight into the divider — peach is 2.64:1 on Latte) fail loudly here.
    @Test("muted-accent divider clears WCAG 1.4.11 for every accent in both themes")
    func dividerAccentClearsContrastFloor() {
        let restFloor = 3.0
        let hoverFloor = 4.0
        let background = NSColor(Color.aw.surface.terminal)

        for accent in AwAccent.allCases {
            for (focused, floor) in [(false, restFloor), (true, hoverFloor)] {
                let divider = NSColor(Color.aw.dividerAccent(accent, focused: focused))
                let label = "\(accent.rawValue) \(focused ? "hover" : "rest")"

                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    guard let dividerResolved = divider.withAppearance(appearance),
                          let backgroundResolved = background.withAppearance(appearance) else {
                        Issue.record("\(label): could not resolve color for \(appearance.rawValue)")
                        continue
                    }

                    let ratio = contrastRatio(dividerResolved, backgroundResolved)
                    #expect(
                        ratio >= floor,
                        "\(label) on \(appearance.rawValue): \(ratio) < \(floor)"
                    )
                }
            }
        }
    }

    // The active-pane focus stripe is drawn over the terminal surface, whose
    // color is independent of the app appearance (INT-285). `focusAccent` picks
    // its variant by contrast against the *terminal* background, not the chrome.
    // The GUARANTEE the picker makes for any background is the WCAG 1.4.11
    // non-text floor (3:1) — the accent hue is kept while it clears 3:1, and on
    // mid-tone terminals where neither variant can (grey / Solarized), it falls
    // back to a black/white neutral that always does. At the dark/light extremes
    // the accent variants clear full AA (4.5:1). This sweep samples the poles AND
    // the mid-tone dead zone so the floor can't silently regress there — the
    // two-pole-only version of this test passed green while mid-greys sat ~2:1.
    @Test("focus-accent stripe holds the non-text floor on any terminal, AA at the poles")
    func focusAccentClearsContrastFloor() {
        let nonTextFloor = 3.0
        let aaFloor = 4.5
        let sweep: [(Color, String, Double)] = [
            (terminalBackgroundHex("#1e1e2e"), "dark #1e1e2e", aaFloor),
            (terminalBackgroundHex("#eff1f5"), "light #eff1f5", aaFloor),
            (terminalBackgroundHex("#808080"), "mid-grey #808080", nonTextFloor),
            (terminalBackgroundHex("#586e75"), "solarized base01 #586e75", nonTextFloor),
            (terminalBackgroundHex("#b0b0b0"), "light-grey #b0b0b0", nonTextFloor),
        ]

        for accent in AwAccent.allCases {
            for (background, backgroundLabel, floor) in sweep {
                guard let stripe = NSColor(Color.aw.focusAccent(accent, terminalBackground: background))
                    .usingColorSpace(.sRGB),
                      let backgroundResolved = NSColor(background).usingColorSpace(.sRGB) else {
                    Issue.record("\(accent.rawValue): could not resolve color for \(backgroundLabel)")
                    continue
                }

                let ratio = contrastRatio(stripe, backgroundResolved)
                #expect(
                    ratio >= floor,
                    "\(accent.rawValue) focus stripe on \(backgroundLabel): \(ratio) < \(floor)"
                )
            }
        }
    }

    @Test("attention stripe holds the non-text floor on mismatched terminal appearances")
    func attentionStripeClearsMismatchedTerminalContrastFloor() {
        let backgrounds: [(Color, String)] = [
            (terminalBackgroundHex("#1e1e2e"), "dark terminal"),
            (terminalBackgroundHex("#eff1f5"), "light terminal"),
        ]

        for (background, label) in backgrounds {
            guard
                let stripe = NSColor(
                    Color.aw.contrastTuned(
                        Color.aw.status.needs,
                        terminalBackground: background
                    )
                ).usingColorSpace(.sRGB),
                let backgroundResolved = NSColor(background).usingColorSpace(.sRGB)
            else {
                Issue.record("Could not resolve attention stripe against \(label)")
                continue
            }

            #expect(
                contrastRatio(stripe, backgroundResolved) >= 3,
                "Attention stripe did not clear 3:1 against \(label)"
            )
        }
    }

    @Test("background crossover chooses a black or white foreground clearing AA")
    func backgroundCrossoverClearsAA() {
        for red in stride(from: 0.0, through: 1.0, by: 0.1) {
            for green in stride(from: 0.0, through: 1.0, by: 0.1) {
                for blue in stride(from: 0.0, through: 1.0, by: 0.1) {
                    let background = Color(red: red, green: green, blue: blue)
                    let foreground = Color.aw.backgroundIsDark(background) ? Color.white : Color.black
                    let ratio = contrastRatio(NSColor(foreground), NSColor(background))

                    #expect(ratio >= 4.5, "rgb(\(red), \(green), \(blue)): \(ratio) < 4.5")
                }
            }
        }
    }

    // The hover-overlay contrast assertion above leans entirely on
    // `composited(over:)` producing the right blended color. Pin the helper's
    // own math so a regression there can't silently weaken a contrast claim.
    @Test("composited(over:) implements straight-alpha source-over")
    func compositedSourceOverMath() {
        func approxEqual(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }

        // Opaque foreground ignores the background entirely.
        let opaque = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let overWhite = opaque.composited(over: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        #expect(approxEqual(overWhite.redComponent, 0.2))
        #expect(approxEqual(overWhite.greenComponent, 0.4))
        #expect(approxEqual(overWhite.blueComponent, 0.6))
        #expect(approxEqual(overWhite.alphaComponent, 1))

        // 50% white over opaque black -> mid grey, fully opaque.
        let halfWhite = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5)
        let grey = halfWhite.composited(over: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        #expect(approxEqual(grey.redComponent, 0.5))
        #expect(approxEqual(grey.alphaComponent, 1))

        // Fully transparent foreground leaves the background untouched.
        let invisible = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 0)
        let background = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let unchanged = invisible.composited(over: background)
        #expect(approxEqual(unchanged.redComponent, 0.2))
        #expect(approxEqual(unchanged.greenComponent, 0.4))
        #expect(approxEqual(unchanged.blueComponent, 0.6))

        // Two transparent layers resolve to nothing (the outputAlpha == 0 guard).
        let nothing = invisible.composited(over: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0))
        #expect(approxEqual(nothing.alphaComponent, 0))
    }

    // INT-155 regression lock. latteHC darkens every SOLID status fill (needs
    // #9b3d07, error #b00030, sapphire #00627d, …). The on-fill foreground
    // token — `onLoud` for all six solid-fill states as of INT-361
    // (`running`'s glyph moved off `onQuiet`; see `AgentTile.swift`) — must
    // therefore go light under latteHC, or each badge collapses to ~2.6:1
    // (the bug this PR introduced by adding the dark latteHC ramp).
    //
    // Resolves through the real `Color.aw.status.*` production tokens (not
    // raw `AwPalette` keyPaths) — as of INT-361, `needs`/`output`/`done`/
    // `running` no longer derive their Latte-family slots structurally from
    // `AwPalette` (they carry their own per-theme hex quadruples, darkened
    // for Latte's non-text floor), so reading the palette directly would
    // silently decouple this test from what it claims to lock. See INT-361
    // gotcha-review finding.
    @Test("status badge foregrounds clear AA on solid latteHC status fills")
    func statusBadgeForegroundsClearContrastOnLatteHCFills() {
        let floor = 4.5
        let solidStatusFills: [(Color, String)] = [
            (Color.aw.status.needs, "needs"),
            (Color.aw.status.error, "error"),
            (Color.aw.status.done, "done"),
            (Color.aw.status.output, "output"),
            (Color.aw.status.waiting, "waiting"),
            (Color.aw.status.running, "running"),
        ]
        guard let foreground = NSColor(Color.aw.status.onLoud)
            .withAppearance(.accessibilityHighContrastAqua) else {
            Issue.record("could not resolve onLoud for latteHC")
            return
        }
        for (fillColor, label) in solidStatusFills {
            guard let fill = NSColor(fillColor).withAppearance(.accessibilityHighContrastAqua) else {
                Issue.record("\(label): could not resolve latteHC appearance")
                continue
            }
            let ratio = contrastRatio(foreground, fill)
            #expect(
                ratio >= floor,
                "latteHC status foreground on \(label) fill: \(ratio) < \(floor)"
            )
        }
    }

    // Locks the fix for INT-361's own live regression: darkening `needs`/
    // `output`/`done`/`running`'s Latte fills for StatusDot's 3:1 non-text
    // floor dropped `onLoud` TEXT contrast on those same solid fills to
    // ~3.1:1 in standard Latte — below WCAG 1.4.3's 4.5:1 text floor — for
    // three real button/badge consumers: `SidebarStatusFooter`'s "Clear
    // search" button, `SessionDetailView`'s "Acknowledge" button, and
    // `SidebarSessionTile.NotificationBadge`'s unread-count pill. All three
    // render actual text/digits, not icons, so they need the stricter text
    // floor the badge glyphs don't. Fixed by flipping `onLoud`'s Latte slot
    // to white; this locks that floor for every solid-fill state including
    // the two left unchanged (`error`/`waiting`), which were ALSO below AA
    // before this fix (3.43:1/3.79:1) and are fixed as a side effect.
    @Test("onLoud text clears WCAG AA on every solid status fill in standard Latte")
    func onLoudTextClearsAAOnSolidLatteFills() {
        let floor = 4.5
        let solidStatusFills: [(Color, String)] = [
            (Color.aw.status.needs, "needs"),
            (Color.aw.status.error, "error"),
            (Color.aw.status.done, "done"),
            (Color.aw.status.output, "output"),
            (Color.aw.status.waiting, "waiting"),
            (Color.aw.status.running, "running"),
        ]
        guard let foreground = NSColor(Color.aw.status.onLoud).withAppearance(.aqua) else {
            Issue.record("could not resolve onLoud for standard Latte")
            return
        }
        for (fillColor, label) in solidStatusFills {
            guard let fill = NSColor(fillColor).withAppearance(.aqua) else {
                Issue.record("\(label): could not resolve Latte appearance")
                continue
            }
            let ratio = contrastRatio(foreground, fill)
            #expect(
                ratio >= floor,
                "onLoud text on \(label) fill, Latte: \(ratio) < \(floor)"
            )
        }
    }

    // INT-698 introduced the remote-permission banner, which draws two new
    // color pairings the solid-fill tests above don't cover. Both sit over the
    // banner's backdrop — `surface.terminal`, the VStack background in
    // SessionDetailView — so the semi-transparent fills are composited over it
    // (per appearance) before the ratio is taken, and each is measured at its
    // lowest-contrast stop.
    @Test("permission-banner queue badge: onLoud digit clears AA on the needs pill")
    func permissionBannerQueueBadgeClearsAAContrast() {
        // The badge renders an actual count digit, so it needs the 4.5:1 text
        // floor. This regression-locks the fill against re-introducing the
        // translucent pill it originally shipped with: `needs.opacity(0.6)`
        // over the near-white Latte `surface.terminal` washed out to ~2.97:1
        // against the white `onLoud` digit. The solid fill (composited over the
        // backdrop is just `needs` itself) is what clears AA.
        let floor = 4.5
        let badgeFill = NSColor(Color.aw.status.needs)
        let foreground = NSColor(Color.aw.status.onLoud)
        let backdrop = NSColor(Color.aw.surface.terminal)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            guard let fill = badgeFill.withAppearance(appearance),
                  let fg = foreground.withAppearance(appearance),
                  let base = backdrop.withAppearance(appearance) else {
                Issue.record("queue badge: could not resolve \(appearance.rawValue)")
                continue
            }
            let composited = fill.composited(over: base)
            let ratio = contrastRatio(fg, composited)
            #expect(
                ratio >= floor,
                "onLoud digit on needs pill over surface.terminal, \(appearance.rawValue): \(ratio) < \(floor)"
            )
        }
    }

    @Test("permission-banner kicker clears AA text contrast on its tint gradient")
    func permissionBannerKickerClearsContrast() {
        // Accessibility-hidden text is still visible text and must clear the
        // normal WCAG 1.4.3 floor. The strongest tint stop is the worst case.
        let floor = 4.5
        let foreground = NSColor(Color.aw.text)
        let tint = NSColor(Color.aw.status.needs.opacity(0.22))
        let backdrop = NSColor(Color.aw.surface.terminal)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            guard let fg = foreground.withAppearance(appearance),
                  let tintResolved = tint.withAppearance(appearance),
                  let base = backdrop.withAppearance(appearance) else {
                Issue.record("kicker: could not resolve \(appearance.rawValue)")
                continue
            }
            let composited = tintResolved.composited(over: base)
            let ratio = contrastRatio(fg, composited)
            #expect(
                ratio >= floor,
                "text kicker on needs@0.22 gradient over surface.terminal, \(appearance.rawValue): \(ratio) < \(floor)"
            )
        }
    }

    // Palette-drift lock, mirroring `dividerRestAndHoverInlineHCMatchesStandaloneHC`
    // above. `needs`/`output`/`done`/`running` each carry a four-hex literal
    // quadruple as of INT-361 (only the Latte slot is a genuinely new value —
    // mocha/mochaHC/latteHC are copies of the corresponding `AwPalette`
    // entries, not KeyPath references into it). Without this lock, a future
    // palette edit (e.g. `AwPalette.mochaHC.peach`) would silently stop
    // propagating to these four tokens, reintroducing the exact HC-desync
    // class of bug INT-155 already fixed once — see INT-361 gotcha-review
    // finding.
    @Test("darkened status tokens' unchanged palette slots match AwPalette")
    func darkenedStatusTokensUnchangedSlotsMatchPalette() {
        let colors = AwColors()
        let cases: [(mocha: String, mochaHC: String, latteHC: String, paletteKey: KeyPath<AwPalette, String>, label: String)] = [
            ("#fab387", "#ffc8a3", "#9b3d07", \.peach, "needs"),
            ("#a6e3a1", "#c2f5bd", "#29661c", \.green, "output"),
            ("#74c7ec", "#9ee4ff", "#00627d", \.sapphire, "running"),
            ("#94e2d5", "#b0f4ea", "#00685c", \.teal, "done"),
        ]
        for (mocha, mochaHC, latteHC, key, label) in cases {
            #expect(mocha == colors.mocha[keyPath: key], "\(label) mocha drifted from AwPalette.mocha")
            #expect(mochaHC == colors.mochaHC[keyPath: key], "\(label) mochaHC drifted from AwPalette.mochaHC")
            #expect(latteHC == colors.latteHC[keyPath: key], "\(label) latteHC drifted from AwPalette.latteHC")
        }
    }

    // F44: rail secondary text must clear WCAG AA on the sidebar mantle in both
    // standard themes. Stock text2 (subtext0) is only 4.06:1 in Latte.
    @Test("railText clears WCAG AA on the sidebar surface")
    func railTextClearsAAOnSidebar() {
        let floor = 4.5
        let foreground = NSColor(Color.aw.railText)
        let background = NSColor(Color.aw.surface.sidebar)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            guard let fg = foreground.withAppearance(appearance),
                  let bg = background.withAppearance(appearance) else {
                Issue.record("railText: could not resolve color for \(appearance.rawValue)")
                continue
            }
            let ratio = contrastRatio(fg, bg)
            #expect(
                ratio >= floor,
                "railText on sidebar \(appearance.rawValue): \(ratio) < \(floor)"
            )
        }
    }

    // Pure-hex lock for railText's four appearance slots. Constructed HC
    // NSAppearances are an unreliable oracle on macOS (host Increase Contrast
    // can leak into `.aqua`), so we pin the mapping table directly — same
    // technique as `awDynamicHelperMapsFourAppearanceMatches`.
    @Test("railText maps each appearance to the AA-safe palette slot")
    func railTextMapsEachAppearanceToAASafePaletteSlot() {
        let colors = AwColors()
        let mocha = colors.mocha.subtext0
        let latte = colors.latte.subtext1
        let mochaHC = colors.mochaHC.subtext0
        let latteHC = colors.latteHC.subtext0

        #expect(NSColor.awDynamicHex(
            for: .darkAqua, mocha: mocha, latte: latte, mochaHC: mochaHC, latteHC: latteHC
        ) == mocha)
        #expect(NSColor.awDynamicHex(
            for: .aqua, mocha: mocha, latte: latte, mochaHC: mochaHC, latteHC: latteHC
        ) == latte)
        #expect(NSColor.awDynamicHex(
            for: .accessibilityHighContrastDarkAqua,
            mocha: mocha, latte: latte, mochaHC: mochaHC, latteHC: latteHC
        ) == mochaHC)
        #expect(NSColor.awDynamicHex(
            for: .accessibilityHighContrastAqua,
            mocha: mocha, latte: latte, mochaHC: mochaHC, latteHC: latteHC
        ) == latteHC)

        // Latte must step off stock subtext0 (text2) — that's the whole point.
        #expect(latte != colors.latte.subtext0)
        #expect(latte == "#5c5f77")
    }

    // F44: sole visual carrier for backgrounded floating-panel work on a
    // session tile. Stock Latte teal is 2.43:1 against surface.elevated.
    @Test("floatingWork indicator clears WCAG 1.4.11 on elevated tiles")
    func floatingWorkIndicatorClearsNonTextFloorOnElevated() {
        let floor = 3.0
        let foreground = NSColor(Color.aw.status.floatingWork)
        let background = NSColor(Color.aw.surface.elevated)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            guard let fg = foreground.withAppearance(appearance),
                  let bg = background.withAppearance(appearance) else {
                Issue.record("floatingWork: could not resolve color for \(appearance.rawValue)")
                continue
            }
            let ratio = contrastRatio(fg, bg)
            #expect(
                ratio >= floor,
                "floatingWork on elevated \(appearance.rawValue): \(ratio) < \(floor)"
            )
        }
    }

    // Locks floatingWork's Latte darkening to the same intentional value as
    // done (shared teal-on-elevated failure class). Pure-hex path so HC host
    // traits cannot mask a drift.
    @Test("floatingWork Latte hex matches done's contrast-tuned teal")
    func floatingWorkLatteHexMatchesDone() {
        let colors = AwColors()
        // awDynamic's production name encodes all four appearance slots, so
        // comparing the real tokens catches drift without relying on the
        // host's potentially high-contrast `.aqua` resolution.
        let done = NSColor(colors.status.done)
        let floatingWork = NSColor(colors.status.floatingWork)
        #expect(floatingWork.colorNameComponent == done.colorNameComponent)

        let floatingWorkLatte = "#116e74"
        #expect(NSColor.awDynamicHex(
            for: .aqua,
            mocha: colors.mocha.teal,
            latte: floatingWorkLatte,
            mochaHC: colors.mochaHC.teal,
            latteHC: colors.latteHC.teal
        ) == floatingWorkLatte)
        #expect(NSColor.awDynamicHex(
            for: .accessibilityHighContrastAqua,
            mocha: colors.mocha.teal,
            latte: floatingWorkLatte,
            mochaHC: colors.mochaHC.teal,
            latteHC: colors.latteHC.teal
        ) == colors.latteHC.teal)
    }
}

private func accentTokens() -> [(KeyPath<AwPalette, String>, String)] {
    [
        (\.rosewater, "rosewater"),
        (\.flamingo, "flamingo"),
        (\.pink, "pink"),
        (\.mauve, "mauve"),
        (\.red, "red"),
        (\.maroon, "maroon"),
        (\.peach, "peach"),
        (\.yellow, "yellow"),
        (\.green, "green"),
        (\.teal, "teal"),
        (\.sky, "sky"),
        (\.sapphire, "sapphire"),
        (\.blue, "blue"),
        (\.lavender, "lavender"),
    ]
}

private func foregroundTokens() -> [(KeyPath<AwPalette, String>, String)] {
    [
        (\.text, "text"),
        (\.subtext1, "subtext1"),
        (\.subtext0, "subtext0"),
        (\.overlay2, "overlay2"),
        (\.overlay1, "overlay1"),
        (\.overlay0, "overlay0"),
    ]
}

private func surfaceTokens() -> [(KeyPath<AwPalette, String>, String)] {
    [
        (\.surface2, "surface2"),
        (\.surface1, "surface1"),
        (\.surface0, "surface0"),
        (\.base, "base"),
        (\.mantle, "mantle"),
        (\.crust, "crust"),
    ]
}

/// Build a SwiftUI `Color` from a `#rrggbb` hex, for synthesizing terminal
/// backgrounds the focus-stripe picker is tested against.
private func terminalBackgroundHex(_ hex: String) -> Color {
    let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    let value = UInt32(trimmed, radix: 16) ?? 0
    return Color(
        red: Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8) & 0xFF) / 255,
        blue: Double(value & 0xFF) / 255
    )
}

/// WCAG 2.x contrast ratio: `(L_hi + 0.05) / (L_lo + 0.05)`.
private func contrastRatio(_ a: NSColor, _ b: NSColor) -> Double {
    let la = relativeLuminance(a)
    let lb = relativeLuminance(b)
    let hi = max(la, lb)
    let lo = min(la, lb)
    return (hi + 0.05) / (lo + 0.05)
}

/// WCAG relative luminance from sRGB components.
private func relativeLuminance(_ color: NSColor) -> Double {
    let c = color.sRGBComponents
    func linearize(_ channel: CGFloat) -> Double {
        let v = Double(channel)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linearize(c.red)
        + 0.7152 * linearize(c.green)
        + 0.0722 * linearize(c.blue)
}

private struct RGBComponents: Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
}

private extension NSColor {
    func withAppearance(_ appearanceName: NSAppearance.Name) -> NSColor? {
        guard let appearance = NSAppearance(named: appearanceName) else {
            return nil
        }

        var resolvedCGColor: CGColor?
        appearance.performAsCurrentDrawingAppearance {
            resolvedCGColor = self.cgColor
        }
        return resolvedCGColor
            .flatMap(NSColor.init(cgColor:))?
            .usingColorSpace(.sRGB)
    }

    var sRGBComponents: RGBComponents {
        RGBComponents(
            red: redComponent,
            green: greenComponent,
            blue: blueComponent
        )
    }

    func composited(over background: NSColor) -> NSColor {
        let foregroundAlpha = alphaComponent
        let backgroundAlpha = background.alphaComponent
        let outputAlpha = foregroundAlpha + backgroundAlpha * (1 - foregroundAlpha)
        guard outputAlpha > 0 else {
            return NSColor.clear
        }

        func blend(_ foreground: CGFloat, _ background: CGFloat) -> CGFloat {
            (foreground * foregroundAlpha
                + background * backgroundAlpha * (1 - foregroundAlpha)) / outputAlpha
        }

        return NSColor(
            srgbRed: blend(redComponent, background.redComponent),
            green: blend(greenComponent, background.greenComponent),
            blue: blend(blueComponent, background.blueComponent),
            alpha: outputAlpha
        )
    }
}

/// Minimal lock-guarded accumulator for the concurrent `awDynamic` tests —
/// `DispatchQueue.concurrentPerform`'s closure isn't `Sendable`-checked
/// against a captured local `var`, so results are collected through an
/// explicit lock rather than relying on the queue's own serialization.
///
/// `@unchecked Sendable` without a `Value: Sendable` constraint is safe only
/// because every access to `storage` (read via `value`, write via `append`)
/// goes through `lock`, and this file never mutates an element after handing
/// it to the box (`NSColor` instances are appended once, then only read).
/// Don't reuse this for a `Value` whose elements can be mutated after
/// insertion — the lock protects the slot, not element internals.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ initial: Value) {
        storage = initial
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append<Element>(_ element: Element) where Value == [Element] {
        lock.lock()
        defer { lock.unlock() }
        storage.append(element)
    }

    func append<Key, Element>(_ element: Element, forKey key: Key) where Value == [Key: [Element]] {
        lock.lock()
        defer { lock.unlock() }
        storage[key, default: []].append(element)
    }
}
