import AwesoMuxLocalAPIAccess
import Darwin
import Foundation

struct CompanionNetworkAddress: Equatable, Sendable {
    let interfaceName: String
    let host: String
    let transport: LocalAPICompanionTransport
    static func selected(_ addresses: [CompanionNetworkAddress]) -> [CompanionNetworkAddress] {
        LocalAPICompanionTransport.allCases.compactMap { transport in
            addresses.filter { $0.transport == transport }.sorted { lhs, rhs in
                if (lhs.interfaceName == "en0") != (rhs.interfaceName == "en0") { return lhs.interfaceName == "en0" }
                if lhs.interfaceName != rhs.interfaceName { return lhs.interfaceName < rhs.interfaceName }
                return lhs.host.split(separator: ".").compactMap { UInt8($0) }.lexicographicallyPrecedes(
                    rhs.host.split(separator: ".").compactMap { UInt8($0) })
            }.first
        }
    }

    static func current() -> [CompanionNetworkAddress] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var result: [CompanionNetworkAddress] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current?.pointee {
            defer { current = entry.ifa_next }
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                entry.ifa_flags & UInt32(IFF_UP) != 0,
                entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            var ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let host = String(
                decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            let bits = UInt32(bigEndian: ipv4.s_addr)
            let netmask = entry.ifa_netmask.map {
                UInt32(bigEndian: UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr)
            }
            let interfaceName = String(cString: entry.ifa_name)
            if let transport = eligibleTransport(interfaceName: interfaceName, bits: bits, flags: entry.ifa_flags, netmask: netmask) {
                result.append(CompanionNetworkAddress(interfaceName: interfaceName, host: host, transport: transport))
            }
        }
        return result
    }

    static func eligibleTransport(interfaceName: String, bits: UInt32, flags: UInt32, netmask: UInt32?) -> LocalAPICompanionTransport? {
        guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { return nil }
        if flags & UInt32(IFF_BROADCAST) != 0, let netmask, netmask != UInt32.max,
            bits | netmask == UInt32.max
        {
            return nil
        }
        // Carrier hotspots also use 100.64/10; only utun addresses qualify.
        if bits & 0xFFC0_0000 == 0x6440_0000, interfaceName.hasPrefix("utun") { return .tailscale }
        let isPrivate = bits & 0xFF00_0000 == 0x0A00_0000 || bits & 0xFFF0_0000 == 0xAC10_0000 || bits & 0xFFFF_0000 == 0xC0A8_0000
        let isTunnel = ["utun", "ipsec", "ppp", "bridge"].contains { interfaceName.hasPrefix($0) }
        return isPrivate && !isTunnel ? .lan : nil
    }
}
