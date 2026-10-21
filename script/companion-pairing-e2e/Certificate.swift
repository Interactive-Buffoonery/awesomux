import CryptoKit
import Darwin
import Foundation
import Security

struct E2EClientIdentity {
    let identity: SecIdentity
    let spki: Data
    private let keyTag: Data
    private let certificateLabel: String

    static func make(receiptPath: String) throws -> Self {
        let identifier = UUID().uuidString.lowercased()
        let label = "awesoMux Companion E2E \(identifier)"
        let tag = Data("com.interactivebuffoonery.awesomux.companion-e2e.\(identifier)".utf8)
        try verifyAbsent(keyTag: tag, certificateLabel: label)
        try writeReceipt(identifier: identifier, path: receiptPath)
        do {
            var error: Unmanaged<CFError>?
            guard
                let privateKey = SecKeyCreateRandomKey(
                    [
                        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                        kSecAttrKeySizeInBits as String: 256,
                        kSecAttrIsPermanent as String: true,
                        kSecAttrApplicationTag as String: tag,
                        kSecAttrLabel as String: label,
                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                    ] as CFDictionary, &error)
            else {
                throw error?.takeRetainedValue() ?? E2EFailure("could not create the client key")
            }
            guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
                throw E2EFailure("could not read the client public key")
            }
            let spki = try E2ECertificate.subjectPublicKeyInfo(for: publicKey)
            let der = try E2ECertificate.make(privateKey: privateKey, publicKey: publicKey, commonName: label)
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                throw E2EFailure("could not create the client certificate")
            }
            let status = SecItemAdd(
                [
                    kSecClass as String: kSecClassCertificate,
                    kSecValueRef as String: certificate,
                    kSecAttrLabel as String: label,
                ] as CFDictionary, nil)
            guard status == errSecSuccess else { throw E2EFailure("could not store the client certificate: \(status)") }
            var identity: SecIdentity?
            guard SecIdentityCreateWithCertificate(nil, certificate, &identity) == errSecSuccess, let identity else {
                throw E2EFailure("could not assemble the client identity")
            }
            return Self(identity: identity, spki: spki, keyTag: tag, certificateLabel: label)
        } catch {
            let constructionError = error
            do {
                try cleanup(keyTag: tag, certificateLabel: label)
            } catch {
                throw E2EFailure("client identity construction failed: \(constructionError); cleanup failed: \(error)")
            }
            throw constructionError
        }
    }

    func cleanup() throws {
        try Self.cleanup(keyTag: keyTag, certificateLabel: certificateLabel)
    }

    private struct OwnershipReceipt: Codable {
        let version: Int
        let runPath: String
        let identifier: String
    }

    private static func receiptLocation(_ path: String) throws -> (path: String, runPath: String) {
        func physical(_ path: String) throws -> String {
            guard let resolved = Darwin.realpath(path, nil) else { throw E2EFailure("cannot resolve client receipt path") }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let url = URL(fileURLWithPath: path)
        let run = try physical(url.deletingLastPathComponent().path)
        let root = try physical("/tmp/companion-pairing-e2e")
        var attributes = stat()
        guard url.lastPathComponent == "client-identity.json",
            (run as NSString).lastPathComponent.hasPrefix("run."),
            (run as NSString).deletingLastPathComponent == root,
            lstat(run, &attributes) == 0, attributes.st_uid == getuid(),
            attributes.st_mode & S_IFMT == S_IFDIR, attributes.st_mode & 0o077 == 0
        else { throw E2EFailure("refusing a non-owned client receipt directory") }
        return (run + "/client-identity.json", run)
    }

    private static func writeReceipt(identifier: String, path: String) throws {
        let location = try receiptLocation(path)
        let data = try JSONEncoder().encode(OwnershipReceipt(version: 1, runPath: location.runPath, identifier: identifier))
        // Claim once, before any permanent Keychain item exists. A partial receipt
        // cannot own items because creation starts only after the durable write.
        let descriptor = open(location.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw E2EFailure("cannot claim client identity receipt: \(errno)") }
        defer { close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw E2EFailure("cannot write client identity receipt: \(errno)") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw E2EFailure("cannot sync client identity receipt: \(errno)") }
    }

    static func cleanup(receiptPath: String) throws {
        let location = try receiptLocation(receiptPath)
        // Open without following a symlink, then validate the opened file itself.
        let descriptor = open(location.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw E2EFailure("cannot open client identity receipt: \(errno)") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_uid == getuid(),
            attributes.st_mode & S_IFMT == S_IFREG, attributes.st_mode & 0o077 == 0,
            attributes.st_size > 0, attributes.st_size <= 4096
        else { throw E2EFailure("invalid client identity receipt attributes") }
        let receipt = try JSONDecoder().decode(OwnershipReceipt.self, from: handle.read(upToCount: 4097) ?? Data())
        guard receipt.version == 1, receipt.runPath == location.runPath,
            let uuid = UUID(uuidString: receipt.identifier), uuid.uuidString.lowercased() == receipt.identifier
        else { throw E2EFailure("invalid client identity ownership receipt") }
        try cleanup(
            keyTag: Data("com.interactivebuffoonery.awesomux.companion-e2e.\(receipt.identifier)".utf8),
            certificateLabel: "awesoMux Companion E2E \(receipt.identifier)")
    }

    private static func itemQueries(keyTag: Data, certificateLabel: String) -> [(String, [String: Any])] {
        var queries: [(String, [String: Any])] = [
            ("certificate", [kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: certificateLabel])
        ]
        for (name, keyClass) in [("private", kSecAttrKeyClassPrivate), ("public", kSecAttrKeyClassPublic)] {
            let base: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass as String: keyClass,
            ]
            // Query both unique identifiers independently so an attribute mismatch
            // cannot hide a retained key. Neither query reaches another run's keys.
            var tagged = base
            tagged[kSecAttrApplicationTag as String] = keyTag
            queries.append(("\(name) key tag", tagged))
            var labelled = base
            labelled[kSecAttrLabel as String] = certificateLabel
            queries.append(("\(name) key label", labelled))
        }
        return queries
    }

    private static func verifyAbsent(keyTag: Data, certificateLabel: String) throws {
        for (name, query) in itemQueries(keyTag: keyTag, certificateLabel: certificateLabel) {
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            guard status == errSecItemNotFound else {
                throw E2EFailure("client identity collision/absence check failed for \(name): \(status)")
            }
        }
    }

    private static func cleanup(keyTag: Data, certificateLabel: String) throws {
        let queries = itemQueries(keyTag: keyTag, certificateLabel: certificateLabel)
        var failures: [String] = []
        for (name, query) in queries {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                failures.append("\(name) delete: \(status)")
            }
        }
        for (name, query) in queries {
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            if status != errSecItemNotFound {
                failures.append("\(name) absence check: \(status)")
            }
        }
        guard failures.isEmpty else {
            throw E2EFailure("client identity cleanup failed [\(certificateLabel)]: " + failures.joined(separator: "; "))
        }
    }
}

enum E2ECertificate {
    static func subjectPublicKeyInfo(for publicKey: SecKey) throws -> Data {
        guard let attributes = SecKeyCopyAttributes(publicKey) as? [CFString: Any],
            attributes[kSecAttrKeyType] as? String == kSecAttrKeyTypeECSECPrimeRandom as String,
            (attributes[kSecAttrKeySizeInBits] as? NSNumber)?.intValue == 256,
            let representation = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
            representation.count == 65, representation.first == 0x04
        else { throw E2EFailure("the certificate key is not P-256") }
        return E2EASN1.sequence(
            E2EASN1.sequence(
                E2EASN1.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]),
                E2EASN1.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
            ),
            E2EASN1.bitString(representation)
        )
    }

    static func subjectPublicKeyInfo(for certificate: SecCertificate) throws -> Data {
        guard let key = SecCertificateCopyKey(certificate) else { throw E2EFailure("peer certificate has no key") }
        return try subjectPublicKeyInfo(for: key)
    }

    static func make(privateKey: SecKey, publicKey: SecKey, commonName: String) throws -> Data {
        let signatureAlgorithm = E2EASN1.sequence(E2EASN1.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
        let name = E2EASN1.sequence(
            E2EASN1.set(
                E2EASN1.sequence(
                    E2EASN1.oid([0x55, 0x04, 0x03]),
                    E2EASN1.utf8String(commonName)
                )))
        var serial = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial) == errSecSuccess else {
            throw E2EFailure("could not create a certificate serial")
        }
        // A positive serial with a nonzero first byte keeps the DER INTEGER minimal.
        serial[0] = serial[0] & 0x7F | 0x40
        let notBefore = Date().addingTimeInterval(-60)
        let notAfter = notBefore.addingTimeInterval(24 * 60 * 60)
        let tbs = E2EASN1.sequence(
            E2EASN1.context(tag: 0, contents: E2EASN1.integer([0x02])),
            E2EASN1.integer(serial),
            signatureAlgorithm,
            name,
            E2EASN1.sequence(E2EASN1.utcTime(notBefore), E2EASN1.utcTime(notAfter)),
            name,
            try subjectPublicKeyInfo(for: publicKey)
        )
        var error: Unmanaged<CFError>?
        guard
            let signature = SecKeyCreateSignature(
                privateKey,
                .ecdsaSignatureMessageX962SHA256,
                tbs as CFData,
                &error
            ) as Data?
        else {
            throw error?.takeRetainedValue() ?? E2EFailure("could not sign the client certificate")
        }
        return E2EASN1.sequence(tbs, signatureAlgorithm, E2EASN1.bitString(signature))
    }
}

private enum E2EASN1 {
    static func sequence(_ values: Data...) -> Data { tagged(0x30, contents: joined(values)) }
    static func set(_ values: Data...) -> Data { tagged(0x31, contents: joined(values)) }
    static func integer(_ bytes: [UInt8]) -> Data { tagged(0x02, contents: Data(bytes)) }
    static func oid(_ bytes: [UInt8]) -> Data { tagged(0x06, contents: Data(bytes)) }
    static func utf8String(_ value: String) -> Data { tagged(0x0C, contents: Data(value.utf8)) }
    static func bitString(_ value: Data) -> Data { tagged(0x03, contents: Data([0]) + value) }
    static func context(tag: UInt8, contents: Data) -> Data { tagged(0xA0 | tag, contents: contents) }

    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tagged(0x17, contents: Data(formatter.string(from: date).utf8))
    }

    private static func joined(_ values: [Data]) -> Data { values.reduce(into: Data()) { $0.append($1) } }

    private static func tagged(_ tag: UInt8, contents: Data) -> Data {
        Data([tag]) + length(contents.count) + contents
    }

    private static func length(_ value: Int) -> Data {
        if value < 128 { return Data([UInt8(value)]) }
        var remaining = value
        var bytes: [UInt8] = []
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
