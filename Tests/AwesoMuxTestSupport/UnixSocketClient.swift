import Darwin
import Foundation

public enum UnixSocketClientError: Error {
    case closed
    case invalidPath
    case system
    case timedOut
}

public final class UnixSocketClient: @unchecked Sendable {
    private let fileDescriptor: Int32

    public init(path: String) throws {
        fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw UnixSocketClientError.system }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fileDescriptor)
            throw UnixSocketClientError.invalidPath
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fileDescriptor, $0, length)
            }
        }
        guard result == 0 else {
            Darwin.close(fileDescriptor)
            throw UnixSocketClientError.system
        }
    }

    deinit {
        Darwin.close(fileDescriptor)
    }

    public func write(_ line: String) throws {
        let data = Data((line + "\n").utf8)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    fileDescriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw UnixSocketClientError.system }
                offset += count
            }
        }
    }

    public func readLine(timeoutMilliseconds: Int32 = 2_000) throws -> String {
        setReceiveTimeout(milliseconds: timeoutMilliseconds)
        var bytes: [UInt8] = []
        while true {
            var byte: UInt8 = 0
            let count = Darwin.read(fileDescriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                throw UnixSocketClientError.timedOut
            }
            guard count == 1 else { throw UnixSocketClientError.closed }
            if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
    }

    public func disconnect() {
        _ = Darwin.shutdown(fileDescriptor, SHUT_RDWR)
    }

    public func waitForEOF(timeoutMilliseconds: Int32) -> Bool {
        setReceiveTimeout(milliseconds: timeoutMilliseconds)
        var byte: UInt8 = 0
        return Darwin.recv(fileDescriptor, &byte, 1, MSG_PEEK) == 0
    }

    public func waitForReadable(timeoutMilliseconds: Int32) -> Bool {
        setReceiveTimeout(milliseconds: timeoutMilliseconds)
        var byte: UInt8 = 0
        return Darwin.recv(fileDescriptor, &byte, 1, MSG_PEEK) >= 0
    }

    private func setReceiveTimeout(milliseconds: Int32) {
        var timeout = timeval(
            tv_sec: Int(milliseconds / 1_000),
            tv_usec: Int32(milliseconds % 1_000) * 1_000
        )
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
    }
}
