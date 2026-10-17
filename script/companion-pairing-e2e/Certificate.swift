import CryptoKit
import Foundation
import Security

struct E2EClientIdentity {
    let identity: SecIdentity
    let spki: Data
    private let keyTag: Data
    private let certificateLabel: String

    static func make() throws -> Self {
        let identifier = UUID().uuidString.lowercased()
        let label = "awesoMux Companion E2E \(identifier)"
        let tag = Data("com.interactivebuffoonery.awesomux.companion-e2e.\(identifier)".utf8)
        var completed = false
        defer {
            if !completed {
                SecItemDelete(
                    [
                        kSecClass as String: kSecClassCertificate,
                        kSecAttrLabel as String: label,
                    ] as CFDictionary)
                SecItemDelete(
                    [
                        kSecClass as String: kSecClassKey,
                        kSecAttrApplicationTag as String: tag,
                        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                    ] as CFDictionary)
            }
        }
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
        completed = true
        return Self(identity: identity, spki: spki, keyTag: tag, certificateLabel: label)
    }

    func cleanup() {
        SecItemDelete(
            [
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: certificateLabel,
            ] as CFDictionary)
        SecItemDelete(
            [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            ] as CFDictionary)
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
        serial[0] &= 0x7F
        if serial.allSatisfy({ $0 == 0 }) { serial[serial.count - 1] = 1 }
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
