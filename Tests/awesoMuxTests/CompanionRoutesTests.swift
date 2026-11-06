import AwesoMuxCompanionProtocol
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import Darwin
import Foundation
import Testing
@testable import awesoMux

struct CompanionRoutesTests {
    // Multiple addresses on en0 must sort numerically without violating strict ordering.
    @Test func selectionIsDeterministic() {
        let addresses = [
            CompanionNetworkAddress(interfaceName: "en1", host: "10.0.0.1", transport: .lan),
            CompanionNetworkAddress(interfaceName: "en0", host: "10.0.0.10", transport: .lan),
            CompanionNetworkAddress(interfaceName: "en0", host: "10.0.0.2", transport: .lan),
            CompanionNetworkAddress(interfaceName: "utun3", host: "100.64.0.2", transport: .tailscale),
        ]
        #expect(CompanionNetworkAddress.selected(addresses).map(\.host) == ["10.0.0.2", "100.64.0.2"])
        #expect(CompanionNetworkAddress.selected(addresses.reversed()).map(\.host) == ["10.0.0.2", "100.64.0.2"])
    }

    @Test func excludesIneligibleInterfacesAndBroadcasts() {
        let up = UInt32(IFF_UP)
        func route(_ name: String, _ bits: UInt32, flags: UInt32? = nil, mask: UInt32? = nil) -> LocalAPICompanionTransport? {
            CompanionNetworkAddress.eligibleTransport(interfaceName: name, bits: bits, flags: flags ?? up, netmask: mask)
        }
        #expect(route("en0", 0xC0A8_0102) == .lan)
        #expect(route("en0", 0xAC1F_0002) == .lan)
        #expect(route("utun2", 0x647F_FFFE) == .tailscale)
        for name in ["utun2", "ipsec0", "ppp0", "bridge0"] { #expect(route(name, 0x0A00_0002) == nil) }
        for bits in [UInt32(0), 0x7F00_0001, 0xA9FE_0001, 0x0808_0808, 0xE000_0001, 0xFFFF_FFFF, 0xAC20_0001] {
            #expect(route("en0", bits) == nil)
        }
        #expect(route("en0", 0x6440_0002) == nil)
        #expect(route("en0", 0x0A00_0002, flags: 0) == nil)
        #expect(route("en0", 0x0A00_0002, flags: up | UInt32(IFF_LOOPBACK)) == nil)
        #expect(route("en0", 0xC0A8_01FF, flags: up | UInt32(IFF_BROADCAST), mask: 0xFFFF_FF00) == nil)
        #expect(route("utun2", 0x6440_0002, mask: 0xFFFF_FFFF) == .tailscale)
    }

    // A read/save must not turn legacy transport metadata into dual-route authority.
    @Test func metadataRetainsLegacyRestriction() throws {
        let legacy = LocalAPICompanionMetadata(
            certificateFingerprint: Data(repeating: 1, count: 32), transport: .lan, pairedAt: Date(), port: 43123)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let saved = try decoder.decode(LocalAPICompanionMetadata.self, from: encoder.encode(legacy))
        #expect(saved == legacy)
        #expect(saved.allows(.lan))
        #expect(!saved.allows(.tailscale))
        let dual = LocalAPICompanionMetadata(
            certificateFingerprint: legacy.certificateFingerprint, transport: .lan, pairedAt: legacy.pairedAt, port: legacy.port,
            pairingVersion: 2)
        let reloaded = try decoder.decode(LocalAPICompanionMetadata.self, from: encoder.encode(dual))
        #expect(reloaded == dual)
        #expect(reloaded.allows(.lan) && reloaded.allows(.tailscale))
    }

    @MainActor @Test func grantStoreRoundTripsBothVersions() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = LocalAPIAccessStore(profile: "development:012345abcdef", supportDirectoryURL: directory)
        let legacy = try store.registerCompanion(
            phoneName: "Legacy", certificateFingerprint: Data(repeating: 1, count: 32), transport: .lan, port: 43123,
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let dual = try store.registerCompanion(
            phoneName: "Dual", certificateFingerprint: Data(repeating: 2, count: 32), transport: .tailscale, port: 43123, pairingVersion: 2,
            pairedAt: Date(timeIntervalSince1970: 1_700_000_001))
        let before = store.state
        try store.retryPersistence()
        store.relinquishAuthority()
        let reloaded = LocalAPIAccessStore.reopened(profile: before.profile, supportDirectoryURL: directory)
        #expect(reloaded.loadFailure == nil)
        #expect(reloaded.state == before)
        #expect(reloaded.state.connections.first { $0.id == legacy.id }?.companion?.allows(.tailscale) == false)
        #expect(reloaded.state.connections.first { $0.id == dual.id }?.companion?.allows(.lan) == true)
    }

    @Test func routesAppearOnlyOnSuccessfulStatus() throws {
        let routes = CompanionRoutes(p: 43123, lan: "10.0.0.2", tailscale: nil)
        let status = LocalAPIResponse(connectionStatus: .connected)
        let withRoutes = try #require(
            JSONSerialization.jsonObject(with: CompanionProtocol.encoder().encode(status.companionResponse(routes: routes)))
                as? [String: Any])
        #expect(withRoutes["routes"] != nil)
        for (response, metadata) in [(status, nil), (LocalAPIResponse(), routes), (LocalAPIResponse(error: .permissionDenied), routes)] {
            let object = try #require(
                JSONSerialization.jsonObject(with: CompanionProtocol.encoder().encode(response.companionResponse(routes: metadata)))
                    as? [String: Any])
            #expect(object["routes"] == nil)
        }
    }

    @Test func routesEncodingOmitsUnavailableAddresses() throws {
        let routes = CompanionRoutes(p: 43123, lan: "10.0.0.2", tailscale: nil)
        let response = try #require(
            JSONSerialization.jsonObject(with: CompanionProtocol.encoder().encode(CompanionAPIResponse(routes: routes))) as? [String: Any])
        let object = try #require(response["routes"] as? [String: Any])
        #expect(object["v"] as? Int == 2)
        #expect(object["p"] as? Int == 43123)
        #expect(object["lan"] as? String == "10.0.0.2")
        #expect(object["tailscale"] == nil)
        let decoded = try CompanionProtocol.decoder().decode(
            CompanionAPIResponse.self, from: CompanionProtocol.encoder().encode(CompanionAPIResponse(routes: routes)))
        #expect(decoded.routes == routes)
    }
}
