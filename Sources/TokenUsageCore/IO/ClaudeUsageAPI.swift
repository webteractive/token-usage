import Foundation

public enum ClaudeUsageAPIError: Error, Equatable {
    /// The token was rejected. Claude Code refreshes it during normal use, so
    /// the remedy is to use Claude Code — not for this app to re-authenticate.
    case unauthorized
    case http(Int)
    case transport(String)
}

/// Fetches the complete quota picture from Claude's OAuth usage endpoint.
///
/// This endpoint is undocumented, so every failure is reported rather than
/// guessed around: if it changes shape or disappears, the app says so and falls
/// back to the statusline source instead of showing a number it cannot justify.
public struct ClaudeUsageAPI: Sendable {

    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let credentials: KeychainCredentials
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(credentials: KeychainCredentials = .init(), session: URLSession = .shared) {
        self.credentials = credentials
        self.transport = { try await session.data(for: $0) }
    }

    init(
        credentials: KeychainCredentials,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.credentials = credentials
        self.transport = transport
    }

    public func fetch(now: Date = .now) async throws -> ProviderUsage {
        let token = try await credentials.accessToken(now: now)
        do {
            return try await fetch(using: token, now: now)
        } catch ClaudeUsageAPIError.unauthorized {
            // Claude Code owns token rotation. If the cached token was revoked,
            // reread its Keychain item once and retry once—never loop.
            let refreshed = try await credentials.accessToken(now: now, forceRefresh: true)
            return try await fetch(using: refreshed, now: now)
        }
    }

    private func fetch(using token: String, now: Date) async throws -> ProviderUsage {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10
        // Quota moves constantly; a cached response would defeat the point.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw ClaudeUsageAPIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeUsageAPIError.transport("no HTTP response")
        }
        guard http.statusCode != 401, http.statusCode != 403 else {
            throw ClaudeUsageAPIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClaudeUsageAPIError.http(http.statusCode)
        }

        return try ClaudeUsageAPIParser.parse(data, observedAt: now)
    }
}
