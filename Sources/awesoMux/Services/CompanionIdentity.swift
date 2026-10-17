import CryptoKit
import Foundation
import Security

struct CompanionIdentity: @unchecked Sendable {
    let identity: SecIdentity
    let certificate: SecCertificate
    let subjectPublicKeyInfo: Data

    var fingerprint: Data { Data(SHA256.hash(data: subjectPublicKeyInfo)) }
}

enum CompanionIdentityError: Error {
    case keychain(OSStatus)
    case invalidKey
    case certificateCreation
    case signing
}

enum CompanionIdentityStore {
    static func loadOrCreate(profile: String) throws -> CompanionIdentity {
        let (tag, label) = identifiers(profile: profile)
        let privateKey = try loadKey(tag: tag) ?? createKey(tag: tag, label: label)

        if let certificate = try loadCertificate(label: label),
            let identity = identity(certificate: certificate),
            CompanionCertificate.isSelfSigned(certificate),
            let spki = try? CompanionCertificate.subjectPublicKeyInfo(for: certificate)
        {
            return CompanionIdentity(identity: identity, certificate: certificate, subjectPublicKeyInfo: spki)
        }

        // A matching private key without a usable certificate can remain after
        // an interrupted first launch. Replace only this profile-namespaced item.
        SecItemDelete(
            [
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: label,
            ] as CFDictionary)
        let publicKey = try publicKey(for: privateKey)
        let spki = try CompanionCertificate.subjectPublicKeyInfo(for: publicKey)
        let certificateDER = try CompanionCertificate.make(privateKey: privateKey, publicKey: publicKey, commonName: label)
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            throw CompanionIdentityError.certificateCreation
        }
        let addStatus = SecItemAdd(
            [
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: certificate,
                kSecAttrLabel as String: label,
            ] as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw CompanionIdentityError.keychain(addStatus)
        }
        guard let stored = try loadCertificate(label: label), let createdIdentity = identity(certificate: stored) else {
            throw CompanionIdentityError.certificateCreation
        }
        return CompanionIdentity(identity: createdIdentity, certificate: stored, subjectPublicKeyInfo: spki)
    }

    static func reset(profile: String) throws {
        let (tag, label) = identifiers(profile: profile)
        for query in [
            [kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label],
            [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            ],
        ] {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CompanionIdentityError.keychain(status)
            }
        }
    }

    private static func identifiers(profile: String) -> (tag: Data, label: String) {
        let namespace = SHA256.hash(data: Data(profile.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return (
            Data("com.interactivebuffoonery.awesomux.companion.\(namespace)".utf8),
            "awesoMux Companion \(namespace)"
        )
    }

    private static func loadKey(tag: Data) throws -> SecKey? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag,
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecReturnRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let key = result as! SecKey? else {
            throw CompanionIdentityError.keychain(status)
        }
        return key
    }

    private static func createKey(tag: Data, label: String) throws -> SecKey {
        var trustedApplication: SecTrustedApplication?
        let trustedStatus = SecTrustedApplicationCreateFromPath(nil, &trustedApplication)
        guard trustedStatus == errSecSuccess, let trustedApplication else {
            throw CompanionIdentityError.keychain(trustedStatus)
        }
        var access: SecAccess?
        let accessStatus = SecAccessCreate(label as CFString, [trustedApplication] as CFArray, &access)
        guard accessStatus == errSecSuccess, let access else {
            throw CompanionIdentityError.keychain(accessStatus)
        }
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tag,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccess as String: access,
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw CompanionIdentityError.invalidKey
        }
        return key
    }

    private static func publicKey(for privateKey: SecKey) throws -> SecKey {
        guard let key = SecKeyCopyPublicKey(privateKey) else { throw CompanionIdentityError.invalidKey }
        return key
    }

    private static func loadCertificate(label: String) throws -> SecCertificate? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: label,
                kSecReturnRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let certificate = result as! SecCertificate? else {
            throw CompanionIdentityError.keychain(status)
        }
        return certificate
    }

    private static func identity(certificate: SecCertificate) -> SecIdentity? {
        var result: SecIdentity?
        guard SecIdentityCreateWithCertificate(nil, certificate, &result) == errSecSuccess else { return nil }
        return result
    }
}

enum CompanionCertificate {
    static func subjectPublicKeyInfo(for publicKey: SecKey) throws -> Data {
        guard let attributes = SecKeyCopyAttributes(publicKey) as? [CFString: Any],
            attributes[kSecAttrKeyType] as? String == kSecAttrKeyTypeECSECPrimeRandom as String,
            (attributes[kSecAttrKeySizeInBits] as? NSNumber)?.intValue == 256,
            let representation = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
            representation.count == 65,
            representation.first == 0x04
        else { throw CompanionIdentityError.invalidKey }
        let algorithm = ASN1.sequence(
            ASN1.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]),
            ASN1.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        )
        return ASN1.sequence(algorithm, ASN1.bitString(representation))
    }

    static func subjectPublicKeyInfo(for certificate: SecCertificate) throws -> Data {
        guard let publicKey = SecCertificateCopyKey(certificate) else { throw CompanionIdentityError.invalidKey }
        return try subjectPublicKeyInfo(for: publicKey)
    }

    static func isSelfSigned(_ certificate: SecCertificate) -> Bool {
        guard let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate) as Data?,
            let subject = SecCertificateCopyNormalizedSubjectSequence(certificate) as Data?,
            issuer == subject,
            let key = SecCertificateCopyKey(certificate),
            let signed = try? signedCertificateParts(SecCertificateCopyData(certificate) as Data),
            signed.algorithm == ASN1.sequence(ASN1.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
        else { return false }
        return SecKeyVerifySignature(
            key,
            .ecdsaSignatureMessageX962SHA256,
            signed.tbs as CFData,
            signed.signature as CFData,
            nil
        )
    }

    static func make(privateKey: SecKey, publicKey: SecKey, commonName: String) throws -> Data {
        let signatureAlgorithm = ASN1.sequence(ASN1.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
        let commonNameAttribute = ASN1.sequence(
            ASN1.oid([0x55, 0x04, 0x03]),
            ASN1.utf8String(commonName)
        )
        let name = ASN1.sequence(ASN1.set(commonNameAttribute))
        var serialBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, serialBytes.count, &serialBytes) == errSecSuccess else {
            throw CompanionIdentityError.certificateCreation
        }
        serialBytes[0] &= 0x7F
        if serialBytes.allSatisfy({ $0 == 0 }) { serialBytes[serialBytes.count - 1] = 1 }
        let calendar = Calendar(identifier: .gregorian)
        let notBefore = Date().addingTimeInterval(-86_400)
        guard let notAfter = calendar.date(byAdding: .year, value: 10, to: notBefore) else {
            throw CompanionIdentityError.certificateCreation
        }
        let validity = ASN1.sequence(ASN1.utcTime(notBefore), ASN1.utcTime(notAfter))
        let tbs = ASN1.sequence(
            ASN1.context(tag: 0, contents: ASN1.integer([0x02])),
            ASN1.integer(serialBytes),
            signatureAlgorithm,
            name,
            validity,
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
            if let error { throw error.takeRetainedValue() }
            throw CompanionIdentityError.signing
        }
        return ASN1.sequence(tbs, signatureAlgorithm, ASN1.bitString(signature))
    }

    private static func signedCertificateParts(_ data: Data) throws -> (tbs: Data, algorithm: Data, signature: Data) {
        let outer = try DERElement.read(from: data, at: 0)
        guard outer.tag == 0x30, outer.endIndex == data.count else { throw CompanionIdentityError.certificateCreation }
        let tbs = try DERElement.read(from: data, at: outer.contentRange.lowerBound)
        let algorithm = try DERElement.read(from: data, at: tbs.endIndex)
        let signature = try DERElement.read(from: data, at: algorithm.endIndex)
        guard tbs.tag == 0x30, algorithm.tag == 0x30, signature.tag == 0x03,
            signature.endIndex == outer.contentRange.upperBound,
            data[signature.contentRange].first == 0
        else { throw CompanionIdentityError.certificateCreation }
        return (
            Data(data[tbs.rawRange]),
            Data(data[algorithm.rawRange]),
            Data(data[signature.contentRange].dropFirst())
        )
    }
}

private struct DERElement {
    let tag: UInt8
    let rawRange: Range<Int>
    let contentRange: Range<Int>
    var endIndex: Int { rawRange.upperBound }

    static func read(from data: Data, at start: Int) throws -> DERElement {
        guard start >= 0, start + 2 <= data.count else { throw CompanionIdentityError.certificateCreation }
        let tag = data[start]
        let firstLength = data[start + 1]
        let headerLength: Int
        let contentLength: Int
        if firstLength & 0x80 == 0 {
            headerLength = 2
            contentLength = Int(firstLength)
        } else {
            let byteCount = Int(firstLength & 0x7F)
            guard byteCount > 0, byteCount <= 4, start + 2 + byteCount <= data.count else {
                throw CompanionIdentityError.certificateCreation
            }
            headerLength = 2 + byteCount
            contentLength = data[(start + 2)..<(start + 2 + byteCount)].reduce(0) { ($0 << 8) | Int($1) }
        }
        let contentStart = start + headerLength
        let end = contentStart + contentLength
        guard end <= data.count else { throw CompanionIdentityError.certificateCreation }
        return DERElement(tag: tag, rawRange: start..<end, contentRange: contentStart..<end)
    }
}

private enum ASN1 {
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

    private static func joined(_ values: [Data]) -> Data {
        values.reduce(into: Data()) { $0.append($1) }
    }

    private static func tagged(_ tag: UInt8, contents: Data) -> Data {
        Data([tag]) + encodedLength(contents.count) + contents
    }

    private static func encodedLength(_ length: Int) -> Data {
        if length < 128 { return Data([UInt8(length)]) }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

extension Data {
    var companionBase64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
