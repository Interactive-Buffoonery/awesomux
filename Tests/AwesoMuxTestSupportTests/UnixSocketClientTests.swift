import Darwin
import Foundation
import Testing
@testable import AwesoMuxTestSupport

@Suite("Unix socket client", .serialized)
struct UnixSocketClientTests {
    @Test("reads a line and observes bounded EOF")
    func readsLineAndEOF() throws {
        let path = "/tmp/awesomux-" + UUID().uuidString + ".sock"
        defer { unlink(path) }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(listener >= 0)
        defer { Darwin.close(listener) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, length)
            }
        }
        #expect(bindResult == 0)
        #expect(Darwin.listen(listener, 1) == 0)

        let client = try UnixSocketClient(path: path)
        let server = Darwin.accept(listener, nil, nil)
        #expect(server >= 0)
        defer { Darwin.close(server) }

        _ = "hello\n".withCString { Darwin.write(server, $0, 6) }
        #expect(try client.readLine() == "hello")
        _ = Darwin.shutdown(server, SHUT_RDWR)
        #expect(client.waitForEOF(timeoutMilliseconds: 200))
    }
}
