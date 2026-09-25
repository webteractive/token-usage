import XCTest
@testable import TokenUsageCore

/// Covers the credential blob handling. The `security` subprocess itself is not
/// exercised here — it needs a real login keychain — but every branch that
/// decides whether its output or a token is usable is.
final class KeychainCredentialsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func blob(token: String, expiresInHours: Double?) -> Data {
        credentialBlob(token: token, now: now, expiresInHours: expiresInHours)
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

    func testSecurityOutputDropsTrailingNewline() throws {
        let output = Data(#"{"claudeAiOauth":{"accessToken":"abc"}}"#.utf8) + Data("\n".utf8)
        let data = try KeychainCredentials.itemData(fromSecurityOutput: output, status: 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"claudeAiOauth":{"accessToken":"abc"}}"#)
    }

    /// 44 is `errSecItemNotFound` as `security` reports it.
    func testMissingItemIsNotFound() {
        XCTAssertThrowsError(
            try KeychainCredentials.itemData(fromSecurityOutput: Data(), status: 44)
        ) { XCTAssertEqual($0 as? CredentialError, .notFound) }
    }

    /// A timed-out read is terminated, so it lands here too.
    func testFailedReadIsNotFound() {
        XCTAssertThrowsError(
            try KeychainCredentials.itemData(fromSecurityOutput: Data("partial".utf8), status: 15)
        ) { XCTAssertEqual($0 as? CredentialError, .notFound) }
    }

    func testEmptyOutputIsNotFound() {
        XCTAssertThrowsError(
            try KeychainCredentials.itemData(fromSecurityOutput: Data("\n".utf8), status: 0)
        ) { XCTAssertEqual($0 as? CredentialError, .notFound) }
    }

    func testRepeatedAccessUsesOneKeychainRead() async throws {
        let source = CredentialDataSource([blob(token: "abc", expiresInHours: 3)])
        let credentials = KeychainCredentials(readData: source.read)

        let first = try await credentials.accessToken(now: now)
        let second = try await credentials.accessToken(now: now.addingTimeInterval(60))
        XCTAssertEqual(first, "abc")
        XCTAssertEqual(second, "abc")
        XCTAssertEqual(source.readCount, 1)
    }

    func testExpiryCausesFreshKeychainRead() async throws {
        let source = CredentialDataSource([
            blob(token: "first", expiresInHours: 1),
            blob(token: "second", expiresInHours: 3),
        ])
        let credentials = KeychainCredentials(readData: source.read)

        let first = try await credentials.accessToken(now: now)
        let second = try await credentials.accessToken(now: now.addingTimeInterval(2 * 3600))
        XCTAssertEqual(first, "first")
        XCTAssertEqual(second, "second")
        XCTAssertEqual(source.readCount, 2)
    }

    func testForcedRefreshBypassesValidCache() async throws {
        let source = CredentialDataSource([
            blob(token: "first", expiresInHours: 3),
            blob(token: "second", expiresInHours: 3),
        ])
        let credentials = KeychainCredentials(readData: source.read)

        let first = try await credentials.accessToken(now: now)
        let second = try await credentials.accessToken(now: now, forceRefresh: true)
        XCTAssertEqual(first, "first")
        XCTAssertEqual(second, "second")
        XCTAssertEqual(source.readCount, 2)
    }

    func testAbsentExpiryStaysCachedForProcess() async throws {
        let source = CredentialDataSource([blob(token: "abc", expiresInHours: nil)])
        let credentials = KeychainCredentials(readData: source.read)

        let first = try await credentials.accessToken(now: now)
        let second = try await credentials.accessToken(
            now: now.addingTimeInterval(365 * 86_400)
        )
        XCTAssertEqual(first, "abc")
        XCTAssertEqual(second, "abc")
        XCTAssertEqual(source.readCount, 1)
    }

    func testConcurrentAccessesShareOneKeychainRead() async throws {
        let source = CredentialDataSource([blob(token: "abc", expiresInHours: 3)])
        let credentials = KeychainCredentials(readData: source.read)
        let now = now

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask { try await credentials.accessToken(now: now) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(tokens, Array(repeating: "abc", count: 10))
        XCTAssertEqual(source.readCount, 1)
    }
}
