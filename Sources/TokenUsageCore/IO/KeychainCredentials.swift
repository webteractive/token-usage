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
/// The token is fetched fresh for each request and never cached to disk.
public struct KeychainCredentials: Sendable {
    public let service: String

    public init(service: String = "Claude Code-credentials") {
        self.service = service
    }

    public func accessToken(now: Date = .now) throws -> String {
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

        return try Self.token(from: data, now: now)
    }

    /// Split out so the JSON handling is testable without a Keychain.
    static func token(from data: Data, now: Date) throws -> String {
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
        return oauth.accessToken
    }
}
