import XCTest
@testable import TokenUsageCore

final class ClaudeAccountTests: XCTestCase {

    func testDefaultAccountUsesUnsuffixedKeychainService() {
        let account = ClaudeAccount(
            id: ClaudeAccount.defaultID,
            directory: URL(fileURLWithPath: "/Users/example/.claude")
        )
        XCTAssertTrue(account.isDefault)
        XCTAssertEqual(account.keychainService, "Claude Code-credentials")
    }

    /// The suffix is the first 8 hex characters of SHA-256 of the directory's
    /// absolute path. These digests are precomputed for the literal paths below.
    func testNonDefaultAccountSuffixesServiceWithPathDigest() {
        let warda = ClaudeAccount(
            id: "warda",
            directory: URL(fileURLWithPath: "/Users/example/.zetty/accounts/warda")
        )
        XCTAssertEqual(warda.keychainService, "Claude Code-credentials-81833aea")

        let devops = ClaudeAccount(
            id: "devops",
            directory: URL(fileURLWithPath: "/Users/example/.zetty/accounts/devops")
        )
        XCTAssertEqual(devops.keychainService, "Claude Code-credentials-4c6515b5")
    }

    /// A trailing slash must not change the digest: Claude Code hashes the path
    /// without one, so a URL built as a directory has to normalise to the same.
    func testTrailingSlashDoesNotChangeService() {
        let plain = ClaudeAccount(
            id: "warda",
            directory: URL(fileURLWithPath: "/Users/example/.zetty/accounts/warda")
        )
        let asDirectory = ClaudeAccount(
            id: "warda",
            directory: URL(fileURLWithPath: "/Users/example/.zetty/accounts/warda", isDirectory: true)
        )
        XCTAssertEqual(plain.keychainService, asDirectory.keychainService)
    }

    func testLabelPrefersDisplayNameAndFallsBackToID() {
        let named = ClaudeAccount(
            id: "warda",
            directory: URL(fileURLWithPath: "/tmp/warda"),
            displayName: "Warda"
        )
        XCTAssertEqual(named.label, "Warda")

        let unnamed = ClaudeAccount(id: "devops", directory: URL(fileURLWithPath: "/tmp/devops"))
        XCTAssertEqual(unnamed.label, "Devops")
    }
}
