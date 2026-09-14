import XCTest
@testable import TokenUsageCore

final class ClaudeAccountLocatorTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var paths: Paths { Paths(home: home) }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    /// Just enough of the real 60KB file to exercise identity resolution.
    private func configJSON(email: String, name: String, org: String) -> String {
        """
        {"numStartups":3,"oauthAccount":{"emailAddress":"\(email)",
        "displayName":"\(name)","organizationName":"\(org)"}}
        """
    }

    private func locator(zetty: Data?) -> ClaudeAccountLocator {
        ClaudeAccountLocator(paths: paths, runZetty: { zetty })
    }

    // MARK: - Primary source

    func testUsesZettyOutputWhenAvailable() throws {
        let json = """
        {"accounts":[{"agent":"claude","directory":"~/.zetty/accounts/warda",
        "id":"warda","name":"Warda","email":"warda@example.com","orgName":"Example Co"}],
        "defaultDirectory":"~/.claude"}
        """
        let accounts = locator(zetty: Data(json.utf8)).discover()

        XCTAssertEqual(accounts.map(\.id), ["default", "warda"])
        XCTAssertEqual(accounts.last?.displayName, "Warda")
    }

    // MARK: - Fallback scan

    /// Without the binary, a directory counts as a Claude account only if it has
    /// a .claude.json — which is what keeps Codex account directories out.
    func testFallbackScanKeepsOnlyDirectoriesWithClaudeConfig() throws {
        try write(
            configJSON(email: "warda@example.com", name: "Warda", org: "Example Co"),
            to: home.appendingPathComponent(".zetty/accounts/warda/.claude.json")
        )
        try write(
            "model = \"gpt-5.6-sol\"\n",
            to: home.appendingPathComponent(".zetty/accounts/personal-test/config.toml")
        )

        let accounts = locator(zetty: nil).discover()

        XCTAssertEqual(accounts.map(\.id), ["default", "warda"])
    }

    func testFallbackReadsIdentityFromTheAccountsOwnConfig() throws {
        try write(
            configJSON(email: "warda@example.com", name: "Warda", org: "Example Co"),
            to: home.appendingPathComponent(".zetty/accounts/warda/.claude.json")
        )

        let warda = try XCTUnwrap(locator(zetty: nil).discover().last)

        XCTAssertEqual(warda.displayName, "Warda")
        XCTAssertEqual(warda.email, "warda@example.com")
        XCTAssertEqual(warda.organizationName, "Example Co")
    }

    func testFallbackUsedWhenZettyOutputIsUnparseable() throws {
        try write(
            configJSON(email: "warda@example.com", name: "Warda", org: "Example Co"),
            to: home.appendingPathComponent(".zetty/accounts/warda/.claude.json")
        )

        let accounts = locator(zetty: Data("not json".utf8)).discover()

        XCTAssertEqual(accounts.map(\.id), ["default", "warda"])
    }

    // MARK: - Identity of the default account

    /// The default login's oauthAccount is at ~/.claude.json, beside its config
    /// directory rather than inside it. ~/.claude/.claude.json does not exist.
    func testDefaultIdentityComesFromHomeLevelConfig() throws {
        try write(
            configJSON(email: "glen@example.com", name: "Glen", org: "Example Co"),
            to: home.appendingPathComponent(".claude.json")
        )

        let fallback = try XCTUnwrap(locator(zetty: nil).discover().first)

        XCTAssertTrue(fallback.isDefault)
        XCTAssertEqual(fallback.displayName, "Glen")
        XCTAssertEqual(fallback.email, "glen@example.com")
    }

    func testZettyListingIsEnrichedWithDefaultIdentity() throws {
        try write(
            configJSON(email: "glen@example.com", name: "Glen", org: "Example Co"),
            to: home.appendingPathComponent(".claude.json")
        )
        let json = #"{"accounts":[],"defaultDirectory":"~/.claude"}"#

        let fallback = try XCTUnwrap(locator(zetty: Data(json.utf8)).discover().first)

        XCTAssertEqual(fallback.displayName, "Glen")
    }

    // MARK: - Degenerate cases

    func testNoZettyDirectoryYieldsOnlyTheDefaultAccount() {
        let accounts = locator(zetty: nil).discover()

        XCTAssertEqual(accounts.map(\.id), ["default"])
        XCTAssertEqual(accounts.first?.directory.path, home.appendingPathComponent(".claude").path)
    }

    /// An account that exists but has never been signed into is still listed —
    /// dropping it is the same failure as showing 0% for "no data".
    func testAccountWithUnreadableIdentityIsStillListed() throws {
        let json = """
        {"accounts":[{"agent":"claude","directory":"~/.zetty/accounts/fresh","id":"fresh"}],
        "defaultDirectory":"~/.claude"}
        """
        let accounts = locator(zetty: Data(json.utf8)).discover()

        XCTAssertEqual(accounts.map(\.id), ["default", "fresh"])
        XCTAssertNil(accounts.last?.displayName)
        XCTAssertEqual(accounts.last?.label, "Fresh")
    }

    // MARK: - Cadence

    /// Full discovery spawns a subprocess, so callers need a cheap way to ask
    /// whether anything changed before paying for it.
    func testFingerprintTracksAccountDirectoryContents() throws {
        let subject = locator(zetty: nil)
        XCTAssertEqual(subject.fingerprint(), [])

        try write(
            configJSON(email: "warda@example.com", name: "Warda", org: "Example Co"),
            to: home.appendingPathComponent(".zetty/accounts/warda/.claude.json")
        )
        XCTAssertEqual(subject.fingerprint(), ["warda"])

        try FileManager.default.removeItem(at: home.appendingPathComponent(".zetty/accounts/warda"))
        XCTAssertEqual(subject.fingerprint(), [])
    }
}
