import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("OSC 8 URL confirmation seam", .serialized)
struct GhosttyRuntimeURLConfirmSeamTests {
    @Test("blocked URL routes through the confirmation provider")
    func blockedURLRoutesThroughProvider() async {
        GhosttyRuntime.resetURLOpenConfirmationProviderForTesting()
        defer { GhosttyRuntime.resetURLOpenConfirmationProviderForTesting() }

        let url = URL(string: "https://evil@example.com")!
        let received: (URL, URLClassifier.BlockReason) = await withCheckedContinuation { continuation in
            GhosttyRuntime.urlOpenConfirmationProvider = { url, reason, _, _ in
                continuation.resume(returning: (url, reason))
                return false
            }
            GhosttyRuntime.openURL(url)
        }

        #expect(received.0 == url)
        #expect(received.1 == .embeddedUserInfo)
    }

    @Test("IDN host routes Unicode and punycode forms through the provider")
    func nonAsciiHostRoutesHostComparisonThroughProvider() async {
        GhosttyRuntime.resetURLOpenConfirmationProviderForTesting()
        defer { GhosttyRuntime.resetURLOpenConfirmationProviderForTesting() }

        // U+0440 CYRILLIC SMALL LETTER ER masquerading as Latin 'p'.
        let url = URL(string: "https://\u{0440}aypal.com/login")!
        let received: (URLClassifier.BlockReason, String?, String?) = await withCheckedContinuation { continuation in
            GhosttyRuntime.urlOpenConfirmationProvider = { _, reason, displayHost, punycodeHost in
                continuation.resume(returning: (reason, displayHost, punycodeHost))
                return false
            }
            GhosttyRuntime.openURL(url)
        }

        #expect(received.0 == .nonAsciiHost)
        #expect(received.1?.unicodeScalars.contains(where: { $0.value > 0x7F }) == true)
        #expect(received.2?.contains("xn--") == true)
        #expect(received.1 != received.2)
    }

    @Test("concurrent block-confirm requests are dropped while one is presented")
    func concurrentRequestsAreDropped() async {
        GhosttyRuntime.resetURLOpenConfirmationProviderForTesting()
        defer { GhosttyRuntime.resetURLOpenConfirmationProviderForTesting() }

        let url = URL(string: "https://evil@example.com")!
        var providerCalls = 0
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            GhosttyRuntime.urlOpenConfirmationProvider = { _, _, _, _ in
                providerCalls += 1
                #expect(GhosttyRuntime.isURLConfirmAlertPresented)
                // A second OSC 8 arriving while the confirm is up must be
                // dropped by the reentry guard, not queued behind it.
                GhosttyRuntime.openURL(url)
                continuation.resume()
                return false
            }
            GhosttyRuntime.openURL(url)
        }

        // Let the spawned Task's defer run so the guard resets.
        await Task.yield()
        #expect(providerCalls == 1)
        #expect(!GhosttyRuntime.isURLConfirmAlertPresented)
    }
}
