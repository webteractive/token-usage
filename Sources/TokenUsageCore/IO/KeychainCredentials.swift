import Foundation
import Security

public enum CredentialError: Error, Equatable {
    case notFound
    case malformed
    /// The access token is past its expiry. Claude Code refreshes it as you
    /// work, so the fix is to use Claude Code, not for this app to intervene.
    case expired
}

/// Reads Claude Code's OAuth access token from the login Keychain.
///
/// Read-only by design. The token is short-lived (hours) and Claude Code
/// refreshes it during normal use; this app never refreshes it and never writes
/// to the Keychain, because doing so would race Claude Code for the same item.
/// The token is cached in memory until expiry and never cached to disk.
public actor KeychainCredentials {
    public let service: String

    public init(service: String = "Claude Code-credentials") {
        self.service = service
        self.readData = { try Self.readKeychainData(service: service) }
    }

    init(
        service: String = "Claude Code-credentials",
        readData: @escaping @Sendable () throws -> Data
    ) {
        self.service = service
        self.readData = readData
    }

    public func accessToken(now: Date = .now, forceRefresh: Bool = false) throws -> String {
        if !forceRefresh, let cached, cached.isValid(at: now) {
            return cached.accessToken
        }

        let credential = try Self.credential(from: readData(), now: now)
        cached = credential
        return credential.accessToken
    }

    private struct Credential: Sendable {
        let accessToken: String
        let expiresAt: Date?

        func isValid(at date: Date) -> Bool {
            expiresAt.map { date < $0 } ?? true
        }
    }

    private let readData: @Sendable () throws -> Data
    private var cached: Credential?

    private static func readKeychainData(service: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { throw CredentialError.notFound }
        return data
    }

    /// Split out so the JSON handling is testable without a Keychain.
    static func token(from data: Data, now: Date) throws -> String {
        try credential(from: data, now: now).accessToken
    }

    private static func credential(from data: Data, now: Date) throws -> Credential {
        struct Blob: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                /// Milliseconds since epoch.
                let expiresAt: Double?
            }
            let claudeAiOauth: OAuth?
        }

        guard let oauth = try? JSONDecoder().decode(Blob.self, from: data).claudeAiOauth,
              !oauth.accessToken.isEmpty
        else { throw CredentialError.malformed }

        if let expiresAt = oauth.expiresAt,
           now.timeIntervalSince1970 >= expiresAt / 1000 {
            throw CredentialError.expired
        }
        return Credential(
            accessToken: oauth.accessToken,
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }
}
