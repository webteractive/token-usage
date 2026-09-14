import XCTest
@testable import TokenUsageCore

final class ZettyAccountsParserTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/example")

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try Data(contentsOf: url)
    }

    func testParsesClaudeAccountsDefaultFirstThenAlphabetical() throws {
        let accounts = try ZettyAccountsParser.parse(fixture("zetty-accounts.json"), home: home)

        XCTAssertEqual(accounts.map(\.id), ["default", "devops", "warda"])
    }

    /// A Codex account directory sits in the same folder. Listing it as a Claude
    /// account would invent a row that reports "not signed in" forever.
    func testExcludesAccountsForOtherAgents() throws {
        let accounts = try ZettyAccountsParser.parse(fixture("zetty-accounts.json"), home: home)

        XCTAssertFalse(accounts.contains { $0.id == "personal-test" })
    }

    func testExpandsTildeAgainstTheInjectedHome() throws {
        let accounts = try ZettyAccountsParser.parse(fixture("zetty-accounts.json"), home: home)

        XCTAssertEqual(
            accounts.first { $0.id == "warda" }?.directory.path,
            "/Users/example/.zetty/accounts/warda"
        )
        XCTAssertEqual(
            accounts.first { $0.id == "default" }?.directory.path,
            "/Users/example/.claude"
        )
    }

    func testCarriesIdentityFromTheListing() throws {
        let accounts = try ZettyAccountsParser.parse(fixture("zetty-accounts.json"), home: home)
        let warda = try XCTUnwrap(accounts.first { $0.id == "warda" })

        XCTAssertEqual(warda.displayName, "Warda")
        XCTAssertEqual(warda.email, "warda@example.com")
        XCTAssertEqual(warda.organizationName, "Example Co")
    }

    /// The default entry is not in the `accounts` array — it is reported
    /// separately — and zetty carries no identity for it.
    func testDefaultAccountIsSynthesisedWithoutIdentity() throws {
        let accounts = try ZettyAccountsParser.parse(fixture("zetty-accounts.json"), home: home)
        let fallback = try XCTUnwrap(accounts.first)

        XCTAssertTrue(fallback.isDefault)
        XCTAssertNil(fallback.displayName)
    }

    func testMalformedOutputThrows() {
        XCTAssertThrowsError(try ZettyAccountsParser.parse(Data("not json".utf8), home: home))
    }
}
