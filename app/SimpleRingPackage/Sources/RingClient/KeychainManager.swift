import Foundation
import Security

// MARK: - Stored Session

/// Everything the app keeps in the Keychain, stored as a single item so macOS
/// asks for Keychain access at most once (rather than once per item).
public struct StoredSession: Codable, Sendable {
    /// Identifies this Mac to Ring. Kept across logouts so logging back in
    /// doesn't register a new device in Ring's Control Center.
    public var hardwareId: String
    public var refreshToken: String?
    public var accessToken: String?
    public var accessTokenExpiry: Date?
}

// MARK: - Keychain Manager

public actor KeychainManager {
    public static let shared = KeychainManager()

    private let service = "dev.simple-ring"
    private let account = "session"
    private var cached: StoredSession?

    private init() {}

    /// Returns the stored session, creating one (with a fresh hardware ID) on first use.
    /// Reads the Keychain only once per launch.
    public func load() throws -> StoredSession {
        if let cached { return cached }
        if let data = try read(), let session = try? JSONDecoder().decode(StoredSession.self, from: data) {
            cached = session
            return session
        }
        let session = StoredSession(hardwareId: UUID().uuidString)
        try save(session)
        return session
    }

    public func save(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.saveFailed(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.saveFailed(status)
        }
        cached = session
    }

    private func read() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.readFailed(status)
        }
    }
}

// MARK: - Keychain Errors

public enum KeychainError: Error, LocalizedError {
    case saveFailed(OSStatus)
    case readFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Failed to save to keychain: \(status)"
        case .readFailed(let status):
            return "Failed to read from keychain: \(status)"
        }
    }
}
