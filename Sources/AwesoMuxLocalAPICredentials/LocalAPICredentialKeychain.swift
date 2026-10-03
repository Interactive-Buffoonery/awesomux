import AwesoMuxLocalAPI
import Foundation
import Security

public enum LocalAPICredentialKeychainError: Error, Equatable, Sendable {
    case invalidProfile
    case invalidCredential
    case alreadyExists
    case unavailable
}

public enum LocalAPICredentialKeychain {
    public static func generate() throws -> Data {
        var bytes = Data(count: LocalAPICredential.byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw LocalAPICredentialKeychainError.unavailable }
        return bytes
    }

    public static func store(_ credential: Data, profile: String, connectionID: UUID) throws {
        guard LocalAPIProfile.isValid(profile) else { throw LocalAPICredentialKeychainError.invalidProfile }
        guard credential.count == LocalAPICredential.byteCount else { throw LocalAPICredentialKeychainError.invalidCredential }
        var query = baseQuery(profile: profile, connectionID: connectionID)
        query[kSecValueData] = credential
        switch SecItemAdd(query as CFDictionary, nil) {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            throw LocalAPICredentialKeychainError.alreadyExists
        default:
            throw LocalAPICredentialKeychainError.unavailable
        }
    }

    public static func load(profile: String, connectionID: UUID) throws -> Data {
        guard LocalAPIProfile.isValid(profile) else { throw LocalAPICredentialKeychainError.invalidProfile }
        var query = baseQuery(profile: profile, connectionID: connectionID)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let credential = result as? Data,
            credential.count == LocalAPICredential.byteCount
        else { throw LocalAPICredentialKeychainError.unavailable }
        return credential
    }

    public static func delete(profile: String, connectionID: UUID) throws {
        guard LocalAPIProfile.isValid(profile) else { throw LocalAPICredentialKeychainError.invalidProfile }
        let status = SecItemDelete(baseQuery(profile: profile, connectionID: connectionID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LocalAPICredentialKeychainError.unavailable
        }
    }

    private static func baseQuery(profile: String, connectionID: UUID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.interactivebuffoonery.awesomux.local-api.\(profile)",
            kSecAttrAccount: connectionID.uuidString.lowercased(),
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
    }
}
