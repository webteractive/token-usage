import XCTest
@testable import TokenUsageCore

/// Covers the credential blob handling. The Keychain lookup itself is not
/// exercised here — it needs a real login keychain — but every branch that
/// decides whether a token is usable is.
final class KeychainCredentialsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func blob(token: String, expiresInHours: Double?) -> Data {
        let expiry = expiresInHours.map { (now.timeIntervalSince1970 + $0 * 3600) * 1000 }
        let oauth: [String: Any] = expiry.map {
            ["accessToken": token, "expiresAt": $0]
        } ?? ["accessToken": token]
        return try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
    }

    func testReadsAccessToken() throws {
        let token = try KeychainCredentials.token(from: blob(token: "abc", expiresInHours: 3), now: now)
        XCTAssertEqual(token, "abc")
    }

    func testMissingOAuthSectionIsMalformed() {
        let data = try! JSONSerialization.data(withJSONObject: ["mcpOAuth": [:]])
        XCTAssertThrowsError(try KeychainCredentials.token(from: data, now: now)) {
            XCTAssertEqual($0 as? CredentialError, .malformed)
        }
    }

    func testEmptyTokenIsMalformed() {
        XCTAssertThrowsError(
            try KeychainCredentials.token(from: blob(token: "", expiresInHours: 3), now: now)
        ) { XCTAssertEqual($0 as? CredentialError, .malformed) }
    }

    /// Reported rather than refreshed: Claude Code owns that token and
    /// refreshing it here would race it for the same Keychain item.
    func testExpiredTokenIsReportedNotRefreshed() {
        XCTAssertThrowsError(
            try KeychainCredentials.token(from: blob(token: "abc", expiresInHours: -1), now: now)
        ) { XCTAssertEqual($0 as? CredentialError, .expired) }
    }

    func testAbsentExpiryIsAccepted() throws {
        XCTAssertEqual(
            try KeychainCredentials.token(from: blob(token: "abc", expiresInHours: nil), now: now),
            "abc"
        )
    }
}
