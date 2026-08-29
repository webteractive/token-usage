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
    private let session: URLSession

    public init(credentials: KeychainCredentials = .init(), session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    public func fetch(now: Date = .now) async throws -> ProviderUsage {
        // Read fresh every time: the token is short-lived and Claude Code may
        // have rotated it since the last poll.
        let token = try credentials.accessToken(now: now)

        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10
        // Quota moves constantly; a cached response would defeat the point.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
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
