# Zetty Account Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show quota for every Claude login on this machine — the default `~/.claude` one plus every zetty account — instead of only the default.

**Architecture:** The app's dictionary key changes from `Provider` (a fixed two-case enum) to a composite `SourceID(provider:account:)`, and render order becomes data (`[SourceDescriptor]`) rather than a hardcoded constant. A new `ClaudeAccountLocator` discovers accounts by asking `zetty accounts --json`, falling back to scanning `~/.zetty/accounts`. Each account is fetched through the **existing** `ClaudeUsageAPI`, built against that account's own Keychain service — no new endpoint, no new parser.

**Tech Stack:** Swift 5.9+, SwiftUI (app target), SPM core library (`TokenUsageCore`, SwiftUI-free), XCTest, CryptoKit (SHA-256), Tuist for project generation.

**Spec:** `docs/superpowers/specs/2026-09-14-zetty-accounts-design.md`

## Global Constraints

- The core library **must stay SwiftUI-free** — `swift test` builds it alone.
- Never write to the Keychain; never log or persist a token. Read-only, in-memory cache only.
- **Never show `0%` for "no data"** — `—` is load-bearing throughout (`WindowState.unknown`).
- Never drop a quota window from a provider's list; the list is open-ended by design.
- Severity is never signalled by colour alone (`●` normal, `▲` warning, `■` critical).
- Render order is fixed and independent of percentages: default Claude account, then zetty accounts alphabetically by id, then Codex.
- `Provider` stays a `String`-raw-valued `CaseIterable` enum — `Preferences` persistence depends on `rawValue`.
- Keychain service names: default = `Claude Code-credentials`; others = that plus `-` plus the first 8 lowercase hex characters of `SHA256(directory.path)`, path taken with **no trailing slash**.
- A machine with no zetty accounts must render **identically to today**: `C 47% · X 3%`, header "Claude".
- **Commit steps require the user's explicit go-ahead** — this repo's global rule is never to `git commit` or `git push` without asking. Never add `Co-Authored-By` or a session URL to a commit message.
- Run `swift test` for core work; `tuist generate --no-open && xcodebuild -workspace TokenUsage.xcworkspace -scheme TokenUsage build` for app-target work.

## File Structure

**Create:**
- `Sources/TokenUsageCore/Model/ClaudeAccount.swift` — one Claude login: id, directory, identity, derived Keychain service.
- `Sources/TokenUsageCore/Model/SourceDescriptor.swift` — `SourceID`, `SourceDescriptor`, and the catalog that turns accounts into ordered, labelled render sources.
- `Sources/TokenUsageCore/Parsing/ZettyAccountsParser.swift` — pure decode of `zetty accounts --json`.
- `Sources/TokenUsageCore/IO/ClaudeAccountLocator.swift` — subprocess primary source, filesystem fallback, identity resolution.
- `Tests/TokenUsageCoreTests/ClaudeAccountTests.swift`
- `Tests/TokenUsageCoreTests/ZettyAccountsParserTests.swift`
- `Tests/TokenUsageCoreTests/ClaudeAccountLocatorTests.swift`
- `Tests/TokenUsageCoreTests/SourceDescriptorTests.swift`
- `Tests/TokenUsageCoreTests/Fixtures/zetty-accounts.json`

**Modify:**
- `Sources/TokenUsageCore/IO/Paths.swift` — add `zettyAccounts`, `defaultClaudeConfigJSON`.
- `Sources/TokenUsageCore/Model/DisplayMode.swift` — add `perAccount`; fix `full` title.
- `Sources/TokenUsageCore/Render/MenuBarLabelRenderer.swift` — rekey to `SourceID`, take `sources`, add `perAccount`.
- `App/UsageViewModel.swift` — rekey state, discover accounts, fetch per account.
- `App/DropdownView.swift` — iterate `model.sources`; wrap in a `ScrollView`.
- `Tests/TokenUsageCoreTests/MenuBarLabelRendererTests.swift`, `ProviderUsageTests.swift` — rekeying plus new cases.
- `README.md` — document accounts and the new mode.

---

### Task 1: `ClaudeAccount` and Keychain service derivation

**Files:**
- Create: `Sources/TokenUsageCore/Model/ClaudeAccount.swift`
- Create: `Tests/TokenUsageCoreTests/ClaudeAccountTests.swift`
- Modify: `Sources/TokenUsageCore/IO/Paths.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ClaudeAccount(id:directory:displayName:email:organizationName:)`, `ClaudeAccount.defaultID` (`"default"`), `.isDefault`, `.keychainService`, `.label`; `Paths.zettyAccounts`, `Paths.defaultClaudeConfigJSON`.

- [ ] **Step 1: Write the failing test**

Create `Tests/TokenUsageCoreTests/ClaudeAccountTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClaudeAccountTests`
Expected: FAIL — "cannot find 'ClaudeAccount' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/TokenUsageCore/Model/ClaudeAccount.swift`:

```swift
import CryptoKit
import Foundation

/// One Claude login on this machine: the default `~/.claude` one, or a zetty
/// account under `~/.zetty/accounts/<id>`.
///
/// Identity fields are optional because an account directory can exist before
/// anyone has signed into it. Such an account is still listed and reports
/// "not signed in" — it exists, and silence about it would be the same failure
/// as printing 0% for "no data".
public struct ClaudeAccount: Equatable, Sendable {
    /// `"default"` for `~/.claude`, otherwise the zetty account id.
    public let id: String
    public let directory: URL
    public let displayName: String?
    public let email: String?
    public let organizationName: String?

    public static let defaultID = "default"
    public static let defaultKeychainService = "Claude Code-credentials"

    public init(
        id: String,
        directory: URL,
        displayName: String? = nil,
        email: String? = nil,
        organizationName: String? = nil
    ) {
        self.id = id
        self.directory = directory
        self.displayName = displayName
        self.email = email
        self.organizationName = organizationName
    }

    public var isDefault: Bool { id == Self.defaultID }

    /// What to call this account in the UI.
    public var label: String { displayName ?? id.capitalized }

    /// Claude Code stores each config directory's OAuth credential under its own
    /// generic-password service. The default directory keeps the bare name;
    /// every other one is suffixed with a digest of its absolute path, so an
    /// account is just the existing API pointed at a different Keychain item.
    public var keychainService: String {
        guard !isDefault else { return Self.defaultKeychainService }
        return "\(Self.defaultKeychainService)-\(Self.serviceSuffix(for: directory))"
    }

    /// `URL.path` yields no trailing slash, which matches what Claude Code
    /// hashes. Normalising here rather than at the call sites keeps a
    /// directory-flavoured URL from producing a different, silently wrong item.
    static func serviceSuffix(for directory: URL) -> String {
        let digest = SHA256.hash(data: Data(directory.path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).lowercased()
    }
}
```

Then add to `Sources/TokenUsageCore/IO/Paths.swift`, after `codexSessions`:

```swift
    public var zettyAccounts: URL {
        home.appendingPathComponent(".zetty/accounts", isDirectory: true)
    }

    /// The default login's `oauthAccount` lives *beside* `~/.claude`, not inside
    /// it — `~/.claude/.claude.json` does not exist. Non-default accounts keep
    /// theirs inside their own config directory.
    public var defaultClaudeConfigJSON: URL {
        home.appendingPathComponent(".claude.json")
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClaudeAccountTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit** (ask the user first)

```bash
git add Sources/TokenUsageCore/Model/ClaudeAccount.swift \
        Sources/TokenUsageCore/IO/Paths.swift \
        Tests/TokenUsageCoreTests/ClaudeAccountTests.swift
git commit -m "feat: model a Claude account and derive its Keychain service"
```

---

### Task 2: Parse `zetty accounts --json`

**Files:**
- Create: `Sources/TokenUsageCore/Parsing/ZettyAccountsParser.swift`
- Create: `Tests/TokenUsageCoreTests/Fixtures/zetty-accounts.json`
- Create: `Tests/TokenUsageCoreTests/ZettyAccountsParserTests.swift`

**Interfaces:**
- Consumes: `ClaudeAccount` from Task 1.
- Produces: `ZettyAccountsParser.parse(_ data: Data, home: URL) throws -> [ClaudeAccount]`, ordered default-first then by id.

- [ ] **Step 1: Write the failing test**

Create `Tests/TokenUsageCoreTests/Fixtures/zetty-accounts.json` — the real shape, including a Codex account that must be filtered out:

```json
{
  "accounts" : [
    {
      "agent" : "claude",
      "directory" : "~/.zetty/accounts/warda",
      "email" : "warda@example.com",
      "id" : "warda",
      "name" : "Warda",
      "orgName" : "Example Co"
    },
    {
      "agent" : "codex",
      "directory" : "~/.zetty/accounts/personal-test",
      "id" : "personal-test",
      "name" : "Personal Test"
    },
    {
      "agent" : "claude",
      "directory" : "~/.zetty/accounts/devops",
      "email" : "devops@example.com",
      "id" : "devops",
      "name" : "Devops",
      "orgName" : "Devops Org"
    }
  ],
  "defaultDirectory" : "~/.claude"
}
```

Create `Tests/TokenUsageCoreTests/ZettyAccountsParserTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ZettyAccountsParserTests`
Expected: FAIL — "cannot find 'ZettyAccountsParser' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/TokenUsageCore/Parsing/ZettyAccountsParser.swift`:

```swift
import Foundation

/// Decodes `zetty accounts --json`.
///
/// zetty is the authority on which account directories belong to which agent —
/// `~/.zetty/accounts/` mixes Claude and Codex logins, and reimplementing that
/// classification means guessing at a contract that can drift.
public enum ZettyAccountsParser {

    private struct Output: Decodable {
        struct Entry: Decodable {
            let agent: String
            let directory: String
            let id: String
            let name: String?
            let email: String?
            let orgName: String?
        }
        let accounts: [Entry]
        let defaultDirectory: String
    }

    public static func parse(_ data: Data, home: URL) throws -> [ClaudeAccount] {
        let output = try JSONDecoder().decode(Output.self, from: data)

        // The default login is reported separately and carries no identity here;
        // it is resolved from ~/.claude.json by the locator.
        let fallback = ClaudeAccount(
            id: ClaudeAccount.defaultID,
            directory: expand(output.defaultDirectory, home: home)
        )

        let named = output.accounts
            .filter { $0.agent == "claude" }
            .map { entry in
                ClaudeAccount(
                    id: entry.id,
                    directory: expand(entry.directory, home: home),
                    displayName: entry.name,
                    email: entry.email,
                    organizationName: entry.orgName
                )
            }
            .sorted { $0.id < $1.id }

        return [fallback] + named
    }

    /// zetty prints paths with `~` rather than expanded, and the home is
    /// injected so this is testable against a fixture.
    private static func expand(_ path: String, home: URL) -> URL {
        guard path.hasPrefix("~/") else { return URL(fileURLWithPath: path) }
        return home.appendingPathComponent(String(path.dropFirst(2)))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ZettyAccountsParserTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit** (ask the user first)

```bash
git add Sources/TokenUsageCore/Parsing/ZettyAccountsParser.swift \
        Tests/TokenUsageCoreTests/ZettyAccountsParserTests.swift \
        Tests/TokenUsageCoreTests/Fixtures/zetty-accounts.json
git commit -m "feat: parse zetty account listings"
```

---

### Task 3: Discover accounts — fallback scan, identity, orchestration

**Files:**
- Create: `Sources/TokenUsageCore/IO/ClaudeAccountLocator.swift`
- Create: `Tests/TokenUsageCoreTests/ClaudeAccountLocatorTests.swift`

**Interfaces:**
- Consumes: `ClaudeAccount`, `Paths.zettyAccounts`, `Paths.defaultClaudeConfigJSON`, `ZettyAccountsParser.parse(_:home:)`.
- Produces: `ClaudeAccountLocator(paths:runZetty:)`, `.discover() -> [ClaudeAccount]` (never empty — always at least the default), `.fingerprint() -> Set<String>`, `ClaudeAccountLocator.locateBinary() -> String?`.

- [ ] **Step 1: Write the failing test**

Create `Tests/TokenUsageCoreTests/ClaudeAccountLocatorTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClaudeAccountLocatorTests`
Expected: FAIL — "cannot find 'ClaudeAccountLocator' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/TokenUsageCore/IO/ClaudeAccountLocator.swift`:

```swift
import Foundation

/// Finds every Claude login on this machine.
///
/// Primary source is `zetty accounts --json`, because zetty owns the mapping
/// from account directory to agent — `~/.zetty/accounts/` holds Codex logins
/// too. The filesystem fallback keeps the app working when zetty is not
/// installed, at the cost of missing an account nobody has signed into yet,
/// which has nothing to report anyway.
///
/// Discovery is not free (a ~28ms subprocess), so callers run it at launch and
/// when the accounts directory changes — never per refresh.
public struct ClaudeAccountLocator: Sendable {

    /// Searched in order. A GUI app does not inherit the shell's PATH, so the
    /// binary has to be located explicitly rather than by name.
    static let searchPaths = [
        "\(NSHomeDirectory())/.local/bin/zetty",
        "/opt/homebrew/bin/zetty",
        "/usr/local/bin/zetty",
    ]

    private let paths: Paths
    private let runZetty: @Sendable () -> Data?

    public init(paths: Paths = .live) {
        self.paths = paths
        self.runZetty = { Self.runListing() }
    }

    init(paths: Paths, runZetty: @escaping @Sendable () -> Data?) {
        self.paths = paths
        self.runZetty = runZetty
    }

    public static func locateBinary() -> String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A cheap signature of the accounts directory: the names it contains.
    ///
    /// `discover()` spawns a ~28ms subprocess, which is not something a menu bar
    /// app should do every minute for an answer that almost never changes.
    /// Callers compare this on each tick and rediscover only when it moves.
    public func fingerprint() -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(
            atPath: paths.zettyAccounts.path
        )) ?? []
        return Set(entries)
    }

    /// Always returns at least the default account, so the app never renders an
    /// empty Claude section on a machine that simply has no zetty.
    public func discover() -> [ClaudeAccount] {
        let discovered = fromZetty() ?? fromFilesystem()
        return discovered.map(withIdentity)
    }

    // MARK: - Sources

    private func fromZetty() -> [ClaudeAccount]? {
        guard let data = runZetty() else { return nil }
        return try? ZettyAccountsParser.parse(data, home: paths.home)
    }

    private func fromFilesystem() -> [ClaudeAccount] {
        let fallback = ClaudeAccount(id: ClaudeAccount.defaultID, directory: paths.claudeDirectory)

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: paths.zettyAccounts,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        let named = entries
            .filter { url in
                // A Claude account has a .claude.json; a Codex one has
                // config.toml instead. Without zetty this is the only signal.
                FileManager.default.fileExists(
                    atPath: url.appendingPathComponent(".claude.json").path
                )
            }
            .map { ClaudeAccount(id: $0.lastPathComponent, directory: $0) }
            .sorted { $0.id < $1.id }

        return [fallback] + named
    }

    // MARK: - Identity

    private func withIdentity(_ account: ClaudeAccount) -> ClaudeAccount {
        // zetty already reports identity for the accounts it lists; only fill in
        // what is missing, which is always the default account and any account
        // discovered by the fallback scan.
        guard account.displayName == nil else { return account }
        guard let identity = readIdentity(for: account) else { return account }

        return ClaudeAccount(
            id: account.id,
            directory: account.directory,
            displayName: identity.displayName,
            email: identity.emailAddress,
            organizationName: identity.organizationName
        )
    }

    private struct Identity: Decodable {
        let displayName: String?
        let emailAddress: String?
        let organizationName: String?
    }

    private func readIdentity(for account: ClaudeAccount) -> Identity? {
        struct Config: Decodable { let oauthAccount: Identity? }

        let url = account.isDefault
            ? paths.defaultClaudeConfigJSON
            : account.directory.appendingPathComponent(".claude.json")

        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data).oauthAccount
    }

    // MARK: - Subprocess

    private static func runListing() -> Data? {
        guard let binary = locateBinary() else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["accounts", "--json"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do { try process.run() } catch { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClaudeAccountLocatorTests`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit** (ask the user first)

```bash
git add Sources/TokenUsageCore/IO/ClaudeAccountLocator.swift \
        Tests/TokenUsageCoreTests/ClaudeAccountLocatorTests.swift
git commit -m "feat: discover Claude accounts via zetty with a filesystem fallback"
```

---

### Task 4: `SourceID`, `SourceDescriptor`, and short labels

**Files:**
- Create: `Sources/TokenUsageCore/Model/SourceDescriptor.swift`
- Create: `Tests/TokenUsageCoreTests/SourceDescriptorTests.swift`

**Interfaces:**
- Consumes: `ClaudeAccount`, `Provider`.
- Produces: `SourceID(provider:account:)`, `SourceID.codex`, `SourceID.claude(_ accountID:)`, `SourceDescriptor(id:displayName:shortLabel:keychainService:)`, `SourceCatalog.descriptors(claudeAccounts:) -> [SourceDescriptor]`.

- [ ] **Step 1: Write the failing test**

Create `Tests/TokenUsageCoreTests/SourceDescriptorTests.swift`:

```swift
import XCTest
@testable import TokenUsageCore

final class SourceDescriptorTests: XCTestCase {

    private func account(_ id: String, _ name: String?) -> ClaudeAccount {
        ClaudeAccount(
            id: id,
            directory: URL(fileURLWithPath: "/Users/example/.zetty/accounts/\(id)"),
            displayName: name
        )
    }

    private func defaultAccount(_ name: String?) -> ClaudeAccount {
        ClaudeAccount(
            id: ClaudeAccount.defaultID,
            directory: URL(fileURLWithPath: "/Users/example/.claude"),
            displayName: name
        )
    }

    /// A machine with no zetty accounts must look exactly like it does today.
    func testSingleAccountKeepsTodaysLabels() {
        let sources = SourceCatalog.descriptors(claudeAccounts: [defaultAccount("Glen")])

        XCTAssertEqual(sources.map(\.displayName), ["Claude", "Codex"])
        XCTAssertEqual(sources.map(\.shortLabel), ["C", "X"])
    }

    func testSeveralAccountsAreNamedAndInitialled() {
        let sources = SourceCatalog.descriptors(claudeAccounts: [
            defaultAccount("Glen"),
            account("devops", "Devops"),
            account("warda", "Warda"),
        ])

        XCTAssertEqual(
            sources.map(\.displayName),
            ["Claude · Glen", "Claude · Devops", "Claude · Warda", "Codex"]
        )
        XCTAssertEqual(sources.map(\.shortLabel), ["G", "D", "W", "X"])
    }

    /// Order is the account order given, then Codex — never by percentage, so
    /// the menu bar does not reshuffle as numbers move.
    func testCodexIsAlwaysLast() {
        let sources = SourceCatalog.descriptors(claudeAccounts: [
            defaultAccount("Glen"), account("warda", "Warda"),
        ])

        XCTAssertEqual(sources.last?.id, SourceID.codex)
        XCTAssertEqual(sources.last?.shortLabel, "X")
        XCTAssertNil(sources.last?.keychainService)
    }

    func testCollidingInitialsGrowToTheShortestUniquePrefix() {
        let sources = SourceCatalog.descriptors(claudeAccounts: [
            defaultAccount("Dave"),
            account("devops", "Devops"),
        ])

        XCTAssertEqual(sources.map(\.shortLabel), ["DA", "DE", "X"])
    }

    /// Codex's fixed X does not compete with Claude accounts for uniqueness.
    func testAccountBeginningWithXKeepsItsInitial() {
        let sources = SourceCatalog.descriptors(claudeAccounts: [
            defaultAccount("Xavier"), account("warda", "Warda"),
        ])

        XCTAssertEqual(sources.map(\.shortLabel), ["X", "W", "X"])
    }

    func testIdenticalNamesAreDisambiguatedPositionally() {
        let sources = SourceCatalog.descriptors(claudeAccounts: [
            defaultAccount("Glen"), account("other", "Glen"),
        ])

        XCTAssertEqual(sources.map(\.shortLabel), ["G1", "G2", "X"])
    }

    func testAccountWithoutIdentityIsNamedFromItsID() {
        let sources = SourceCatalog.descriptors(claudeAccounts: [
            defaultAccount("Glen"), account("fresh", nil),
        ])

        XCTAssertEqual(sources[1].displayName, "Claude · Fresh")
        XCTAssertEqual(sources[1].shortLabel, "F")
    }

    func testDescriptorsCarryTheAccountsKeychainService() {
        let sources = SourceCatalog.descriptors(claudeAccounts: [
            defaultAccount("Glen"), account("warda", "Warda"),
        ])

        XCTAssertEqual(sources[0].keychainService, "Claude Code-credentials")
        XCTAssertEqual(sources[1].keychainService, "Claude Code-credentials-81833aea")
        XCTAssertEqual(sources[1].id, SourceID.claude("warda"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SourceDescriptorTests`
Expected: FAIL — "cannot find 'SourceCatalog' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/TokenUsageCore/Model/SourceDescriptor.swift`:

```swift
import Foundation

/// Identifies one row of the app: a provider, and for Claude, which login.
///
/// This replaces `Provider` as the key of every usage dictionary. `Provider`
/// survives unchanged — it answers *which vendor* — it simply stops being
/// specific enough to name a row now that one vendor can have several logins.
public struct SourceID: Hashable, Sendable {
    public let provider: Provider
    /// `nil` for a provider with a single login.
    public let account: String?

    public init(provider: Provider, account: String?) {
        self.provider = provider
        self.account = account
    }

    public static let codex = SourceID(provider: .codex, account: nil)

    public static func claude(_ accountID: String) -> SourceID {
        SourceID(provider: .claude, account: accountID)
    }
}

/// Everything the renderer and dropdown need to draw one row, resolved once at
/// discovery so nothing downstream recomputes labels or ordering.
public struct SourceDescriptor: Equatable, Sendable {
    public let id: SourceID
    public let displayName: String
    public let shortLabel: String
    /// `nil` for providers this app holds no credential for.
    public let keychainService: String?

    public init(id: SourceID, displayName: String, shortLabel: String, keychainService: String?) {
        self.id = id
        self.displayName = displayName
        self.shortLabel = shortLabel
        self.keychainService = keychainService
    }
}

public enum SourceCatalog {

    /// Builds the ordered render list: Claude accounts in the order given, then
    /// Codex. Never ordered by percentage — the menu bar must not reshuffle as
    /// numbers move.
    public static func descriptors(claudeAccounts: [ClaudeAccount]) -> [SourceDescriptor] {
        let labels = shortLabels(for: claudeAccounts.map(\.label))
        let single = claudeAccounts.count == 1

        let claude = zip(claudeAccounts, labels).map { account, label in
            SourceDescriptor(
                id: .claude(account.id),
                // With one login there is nothing to disambiguate, so the app
                // reads exactly as it did before accounts existed.
                displayName: single
                    ? Provider.claude.displayName
                    : "\(Provider.claude.displayName) · \(account.label)",
                shortLabel: single ? Provider.claude.shortLabel : label,
                keychainService: account.keychainService
            )
        }

        return claude + [
            SourceDescriptor(
                id: .codex,
                displayName: Provider.codex.displayName,
                shortLabel: Provider.codex.shortLabel,
                keychainService: nil
            )
        ]
    }

    /// The shortest uppercase prefix that tells these names apart. Uniqueness is
    /// resolved among Claude accounts only — Codex's fixed `X` does not compete,
    /// because the two never need telling apart from each other.
    static func shortLabels(for names: [String]) -> [String] {
        let upper = names.map { $0.uppercased() }
        let longest = upper.map(\.count).max() ?? 1

        for length in 1...max(longest, 1) {
            let candidates = upper.map { String($0.prefix(length)) }
            if Set(candidates).count == candidates.count { return candidates }
        }

        // Genuinely identical names: a position beats two identical letters.
        return upper.enumerated().map { "\($0.element.prefix(1))\($0.offset + 1)" }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SourceDescriptorTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit** (ask the user first)

```bash
git add Sources/TokenUsageCore/Model/SourceDescriptor.swift \
        Tests/TokenUsageCoreTests/SourceDescriptorTests.swift
git commit -m "feat: key usage rows by source rather than provider"
```

---

### Task 5: Rekey the renderer and add the per-account mode

**Files:**
- Modify: `Sources/TokenUsageCore/Model/DisplayMode.swift`
- Modify: `Sources/TokenUsageCore/Render/MenuBarLabelRenderer.swift`
- Modify: `Tests/TokenUsageCoreTests/MenuBarLabelRendererTests.swift`

`ProviderUsageTests` needs **no change**: it only asserts on `Provider.claude.shortLabel` and friends, never using `Provider` as a dictionary key.

**Interfaces:**
- Consumes: `SourceID`, `SourceDescriptor`, `SourceCatalog` from Task 4.
- Produces: `MenuBarLabelRenderer.render(usage:sources:mode:thresholds:now:) -> LabelSpec`; `DisplayMode.perAccount`.

- [ ] **Step 1: Write the failing test**

Replace the helpers at the top of `Tests/TokenUsageCoreTests/MenuBarLabelRendererTests.swift` (the `usage(claude:codex:)`, `sample` and `render(_:_:)` members) with:

```swift
    private func account(_ id: String, _ name: String) -> ClaudeAccount {
        ClaudeAccount(
            id: id,
            directory: URL(fileURLWithPath: "/Users/example/.zetty/accounts/\(id)"),
            displayName: name
        )
    }

    private var soleAccount: [ClaudeAccount] {
        [ClaudeAccount(
            id: ClaudeAccount.defaultID,
            directory: URL(fileURLWithPath: "/Users/example/.claude"),
            displayName: "Glen"
        )]
    }

    private func usage(claude: ProviderUsage, codex: ProviderUsage) -> [SourceID: ProviderUsage] {
        [.claude(ClaudeAccount.defaultID): claude, .codex: codex]
    }

    private var sample: [SourceID: ProviderUsage] {
        usage(
            claude: pair(session: window(47), weekly: window(31)),
            codex: pair(session: window(3), weekly: window(1))
        )
    }

    private func render(
        _ mode: DisplayMode,
        _ u: [SourceID: ProviderUsage],
        accounts: [ClaudeAccount]? = nil
    ) -> LabelSpec {
        MenuBarLabelRenderer.render(
            usage: u,
            sources: SourceCatalog.descriptors(claudeAccounts: accounts ?? soleAccount),
            mode: mode,
            thresholds: .default,
            now: now
        )
    }
```

Then append these new tests to the same file:

```swift
    // MARK: - Several accounts

    private var threeAccounts: [ClaudeAccount] {
        soleAccount + [account("devops", "Devops"), account("warda", "Warda")]
    }

    private var multiAccountSample: [SourceID: ProviderUsage] {
        [
            .claude(ClaudeAccount.defaultID): pair(session: window(47), weekly: window(31)),
            .claude("devops"): pair(session: window(80), weekly: window(64)),
            .claude("warda"): pair(session: window(12), weekly: window(8)),
            .codex: pair(session: window(3), weekly: window(1)),
        ]
    }

    /// The default mode must keep the bar a fixed width however many logins
    /// exist, so Claude collapses to whichever account is closest to a wall.
    func testPerToolCollapsesAccountsToTheWorst() {
        let segs = render(.perTool, multiAccountSample, accounts: threeAccounts)

        XCTAssertEqual(segs.map(\.text), ["C ▲ 80%", "X 3%"])
        XCTAssertEqual(segs[0].severity, .warning)
    }

    func testPerAccountShowsEverySourceSeparately() {
        let segs = render(.perAccount, multiAccountSample, accounts: threeAccounts)

        XCTAssertEqual(segs.map(\.text), ["G 47%", "D ▲ 80%", "W 12%", "X 3%"])
    }

    func testPerAccountWithOneAccountMatchesPerTool() {
        XCTAssertEqual(
            render(.perAccount, sample).map(\.text),
            render(.perTool, sample).map(\.text)
        )
    }

    func testWorstOfSpansAccounts() {
        let segs = render(.worstOf, multiAccountSample, accounts: threeAccounts)

        XCTAssertEqual(segs.map(\.text), ["▲ 80%"])
    }

    func testFullShowsEveryWindowOfEverySource() {
        let segs = render(.full, multiAccountSample, accounts: threeAccounts)

        XCTAssertEqual(segs.map(\.text), ["G 47/31", "D ▲ 80/64", "W 12/8", "X 3/1"])
    }

    func testAccountWithNoDataRendersEmDashNeverZero() {
        var partial = multiAccountSample
        partial[.claude("warda")] = .empty
        let segs = render(.perAccount, partial, accounts: threeAccounts)

        XCTAssertEqual(segs[2].text, "W —")
        XCTAssertFalse(segs[2].hasData)
    }

    func testEveryWindowModeIsNamedForWhatItShows() {
        XCTAssertEqual(DisplayMode.full.title, "Every window")
        XCTAssertEqual(DisplayMode.perAccount.title, "One per account")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MenuBarLabelRendererTests`
Expected: FAIL to compile — "extra argument 'sources' in call" and "type 'DisplayMode' has no member 'perAccount'".

- [ ] **Step 3: Write minimal implementation**

In `Sources/TokenUsageCore/Model/DisplayMode.swift`, add the case between `perTool` and `full` and fix the stale title:

```swift
public enum DisplayMode: String, CaseIterable, Sendable, Identifiable {
    case worstOf
    case perTool
    case perAccount
    case full

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .worstOf: "Worst of all windows"
        case .perTool: "One per tool"
        case .perAccount: "One per account"
        // "All four" stopped being true when scoped weekly limits appeared, and
        // the README already documents this name.
        case .full: "Every window"
        }
    }
}
```

Replace `Sources/TokenUsageCore/Render/MenuBarLabelRenderer.swift` entirely:

```swift
import Foundation

public enum MenuBarLabelRenderer {

    /// Sources arrive in a fixed order resolved at discovery, so the bar does
    /// not reshuffle as numbers change.
    public static func render(
        usage: [SourceID: ProviderUsage],
        sources: [SourceDescriptor],
        mode: DisplayMode,
        thresholds: Thresholds = .default,
        now: Date
    ) -> LabelSpec {
        switch mode {
        case .worstOf: renderWorstOf(usage, sources, thresholds, now)
        case .perTool: renderPerTool(usage, sources, thresholds, now)
        case .perAccount: renderPerSource(usage, sources, thresholds, now, windows: false)
        case .full: renderPerSource(usage, sources, thresholds, now, windows: true)
        }
    }

    // MARK: - Modes

    private static func renderWorstOf(
        _ usage: [SourceID: ProviderUsage],
        _ sources: [SourceDescriptor],
        _ thresholds: Thresholds,
        _ now: Date
    ) -> LabelSpec {
        let states = sources.compactMap { usage[$0.id]?.dominant(now: now) }.filter(\.hasData)
        guard let worst = states.max(by: { ($0.percent ?? 0) < ($1.percent ?? 0) }) else {
            return [Segment(text: "—", severity: .normal, isStale: false, hasData: false)]
        }
        let severity = Severity.of(worst.percent ?? 0, thresholds)
        // The marker doubles as this mode's identity glyph, so it is always
        // shown and simply changes shape with severity.
        let text = "\(severity.marker) \(stalePrefix(worst))\(worst.percentLabel)"
        return [Segment(text: text, severity: severity, isStale: worst.isStale, hasData: true)]
    }

    /// One segment per vendor: several Claude logins collapse to whichever is
    /// closest to a wall. This is what keeps the bar a fixed width as accounts
    /// are added, which is why it stays the default.
    private static func renderPerTool(
        _ usage: [SourceID: ProviderUsage],
        _ sources: [SourceDescriptor],
        _ thresholds: Thresholds,
        _ now: Date
    ) -> LabelSpec {
        var seen: [Provider] = []
        for source in sources where !seen.contains(source.id.provider) {
            seen.append(source.id.provider)
        }

        return seen.map { provider in
            let states = sources
                .filter { $0.id.provider == provider }
                .compactMap { usage[$0.id]?.dominant(now: now) }
                .filter(\.hasData)
            let worst = states.max(by: { ($0.percent ?? 0) < ($1.percent ?? 0) }) ?? .unknown

            return segment(label: provider.shortLabel, state: worst, body: nil, thresholds)
        }
    }

    /// One segment per source — per account for Claude. `windows` decides
    /// whether the body is the dominant figure or every window it reports.
    private static func renderPerSource(
        _ usage: [SourceID: ProviderUsage],
        _ sources: [SourceDescriptor],
        _ thresholds: Thresholds,
        _ now: Date,
        windows: Bool
    ) -> LabelSpec {
        sources.map { source in
            let provided = usage[source.id] ?? .empty
            let dominant = provided.dominant(now: now)
            let body = windows
                ? provided.windows.map { $0.window.state(now: now).numberLabel }.joined(separator: "/")
                : nil

            return segment(label: source.shortLabel, state: dominant, body: body, thresholds)
        }
    }

    // MARK: - Formatting

    private static func segment(
        label: String,
        state: WindowState,
        body: String?,
        _ thresholds: Thresholds
    ) -> Segment {
        let severity = Severity.of(state.percent ?? 0, thresholds)
        let text: String
        if state.hasData {
            let figures = body ?? state.percentLabel
            text = "\(label) \(marker(severity))\(stalePrefix(state))\(figures)"
        } else {
            text = "\(label) —"
        }
        return Segment(
            text: text,
            severity: state.hasData ? severity : .normal,
            isStale: state.isStale,
            hasData: state.hasData
        )
    }

    /// Shown only when it carries information; a marker on every normal reading
    /// would just be noise.
    private static func marker(_ severity: Severity) -> String {
        severity == .normal ? "" : "\(severity.marker) "
    }

    private static func stalePrefix(_ state: WindowState) -> String {
        state.isStale ? "‹" : ""
    }
}
```

- [ ] **Step 4: Run the full core suite**

Run: `swift test`
Expected: PASS, whole suite. Every pre-existing renderer test routes through the two helpers replaced in Step 1, so none of their assertions change.

- [ ] **Step 5: Commit** (ask the user first)

```bash
git add Sources/TokenUsageCore/Model/DisplayMode.swift \
        Sources/TokenUsageCore/Render/MenuBarLabelRenderer.swift \
        Tests/TokenUsageCoreTests/MenuBarLabelRendererTests.swift
git commit -m "feat: render one segment per account and add the per-account mode"
```

---

### Task 6: Fetch every account in the view model

**Files:**
- Modify: `App/UsageViewModel.swift`

**Interfaces:**
- Consumes: `ClaudeAccountLocator`, `SourceCatalog`, `SourceID`, `SourceDescriptor`, `MenuBarLabelRenderer.render(usage:sources:mode:thresholds:now:)`.
- Produces: `UsageViewModel.sources: [SourceDescriptor]`, `.usage: [SourceID: ProviderUsage]`, `.sourceStatus: [SourceID: SourceStatus]`.

This task has no unit test — `UsageViewModel` is `@MainActor` SwiftUI-adjacent app-target code with no test target, which is exactly why the logic worth testing lives in the core. Verification is a build plus a run.

- [ ] **Step 1: Rekey the stored state**

In `App/UsageViewModel.swift`, replace the three stored dictionaries and add the source list:

```swift
    private(set) var usage: [SourceID: ProviderUsage] = [:]
    private(set) var shimStatus: ShimStatus = .notInstalled(existingCommand: nil)
    /// The ordered render list, rebuilt only when the set of accounts changes.
    private(set) var sources: [SourceDescriptor] = []
    /// How each source's figures were obtained, so the UI can be honest about
    /// it. Both providers have a live source and a degraded fallback, so they
    /// share one type rather than two near-identical ones.
    private(set) var sourceStatus: [SourceID: SourceStatus] = [:]
```

Replace the throttle map and its helper:

```swift
    private var lastFetch: [SourceID: Date] = [:]
    private static let minimumFetchInterval: TimeInterval = 60

    private func shouldFetch(_ source: SourceID, now: Date = .now) -> Bool {
        guard let last = lastFetch[source] else { return true }
        return now.timeIntervalSince(last) >= Self.minimumFetchInterval
    }
```

- [ ] **Step 2: Add discovery and the per-account API cache**

Add these properties beside `api`, and delete the existing `private let api: ClaudeUsageAPI`:

```swift
    private let locator: ClaudeAccountLocator
    /// The last seen shape of `~/.zetty/accounts`, so the 60s tick can skip the
    /// subprocess when nothing has changed.
    private var accountsFingerprint: Set<String>?
    /// One API per account, kept alive across refreshes. This is load-bearing:
    /// each owns a `KeychainCredentials` actor holding the cached token, so
    /// rebuilding them per refresh would re-read every Keychain item — once per
    /// account, every minute — and undo the fix in 74e9bbb.
    private var apis: [SourceID: ClaudeUsageAPI] = [:]
    private var accounts: [ClaudeAccount] = []
```

In `init`, replace `self.api = ClaudeUsageAPI()` with:

```swift
        self.locator = ClaudeAccountLocator(paths: paths)
```

Add the discovery method:

```swift
    /// Rebuilds the source list only when the account set actually changed, so
    /// a steady state costs nothing and no Keychain item is re-read.
    private func rediscoverAccounts() {
        // A directory listing is cheap; discovery is a subprocess. Pay for the
        // second only when the first says something moved.
        let fingerprint = locator.fingerprint()
        guard fingerprint != accountsFingerprint || sources.isEmpty else { return }
        accountsFingerprint = fingerprint

        let found = locator.discover()
        guard found != accounts || sources.isEmpty else { return }

        accounts = found
        sources = SourceCatalog.descriptors(claudeAccounts: found)

        var rebuilt: [SourceID: ClaudeUsageAPI] = [:]
        for account in found {
            let id = SourceID.claude(account.id)
            // Reuse the existing client — and its cached token — where the
            // account is unchanged.
            rebuilt[id] = apis[id] ?? ClaudeUsageAPI(
                credentials: KeychainCredentials(service: account.keychainService)
            )
        }
        apis = rebuilt

        // Drop state belonging to accounts that no longer exist.
        let live = Set(sources.map(\.id))
        usage = usage.filter { live.contains($0.key) }
        sourceStatus = sourceStatus.filter { live.contains($0.key) }
        lastFetch = lastFetch.filter { live.contains($0.key) }
    }
```

- [ ] **Step 3: Fetch accounts concurrently**

Replace `refreshClaude()` with an account-aware pair, and update `refresh()`:

```swift
    func refresh() {
        shimStatus = installer.status()
        rediscoverAccounts()
        Task { await refreshClaude() }
        Task { await refreshCodex() }
    }

    private func refreshClaude() async {
        // Separate logins have separate server-side limits, so they are fetched
        // concurrently and throttled independently.
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { @MainActor [weak self] in
                    await self?.refreshClaudeAccount(account)
                }
            }
        }
    }

    /// The API is preferred because it is complete — it carries scoped weekly
    /// limits the statusline never sends — and because it is live rather than
    /// only arriving while a session happens to be running. The statusline
    /// capture stays as a fallback, but it covers the default account only: the
    /// shim is installed into ~/.claude/settings.json and sees nothing else.
    private func refreshClaudeAccount(_ account: ClaudeAccount) async {
        let id = SourceID.claude(account.id)
        guard let api = apis[id], shouldFetch(id) else { return }
        lastFetch[id] = .now

        var reason = "unavailable"
        do {
            usage[id] = try await api.fetch()
            sourceStatus[id] = .live
            return
        } catch ClaudeUsageAPIError.unauthorized {
            reason = "sign-in expired — run claude"
        } catch CredentialError.expired {
            reason = "sign-in expired — run claude"
        } catch CredentialError.notFound {
            reason = "not signed in"
        } catch ClaudeUsageAPIError.http(429) {
            // The usage endpoint rate-limits its own callers. Backing off and
            // keeping the last reading beats thrashing it.
            reason = "rate limited — retrying shortly"
        } catch {
            reason = "usage API unavailable"
        }

        // The statusline capture carries only two windows, so a partial view is
        // never presented as if it were the whole picture.
        if account.isDefault, let fallback = readClaude() {
            usage[id] = fallback
            sourceStatus[id] = .degraded("statusline · partial")
        } else if usage[id]?.windows.isEmpty == false {
            sourceStatus[id] = .degraded("last known")
        } else {
            usage[id] = .empty
            sourceStatus[id] = .unavailable(reason)
        }
    }
```

In `refreshCodex()`, replace every `usage[.codex]`, `sourceStatus[.codex]`, `shouldFetch(.codex)` and `lastFetch[.codex]` with the `SourceID` form — `usage[SourceID.codex]` and so on. The method body is otherwise unchanged.

- [ ] **Step 4: Watch the accounts directory and feed the renderer**

Update `labelSpec` to pass the sources:

```swift
    var labelSpec: LabelSpec {
        MenuBarLabelRenderer.render(
            usage: usage,
            sources: sources,
            mode: preferences.displayMode,
            thresholds: preferences.thresholds,
            now: .now
        )
    }
```

And in `start()`, add the accounts directory to the watcher:

```swift
        watcher = FileWatcher(
            urls: [paths.stateDirectory, paths.codexSessions, paths.zettyAccounts]
        ) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
```

- [ ] **Step 5: Build and run**

Run: `tuist generate --no-open && xcodebuild -workspace TokenUsage.xcworkspace -scheme TokenUsage build`
Expected: BUILD SUCCEEDED.

Then launch the app and confirm: the dropdown lists every account, the menu bar reads `C … · X …` in the default mode, and the Keychain prompts once per account (approve each). If an account shows "not signed in" that it should not, check its Keychain service name against `security dump-keychain | grep 'Claude Code-credentials'`.

- [ ] **Step 6: Commit** (ask the user first)

```bash
git add App/UsageViewModel.swift
git commit -m "feat: fetch quota for every Claude account"
```

---

### Task 7: Show every account in the dropdown

**Files:**
- Modify: `App/DropdownView.swift`

**Interfaces:**
- Consumes: `UsageViewModel.sources`, `.usage`, `.sourceStatus` from Task 6.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Iterate sources instead of providers**

In `App/DropdownView.swift`, replace the `ForEach(Provider.allCases, id: \.self)` block with a scrolling list of sources. `SourceID` is already `Hashable`, so it can be the identity directly:

```swift
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.sources, id: \.id) { source in
                        sourceSection(source)
                    }
                }
            }
            // Enough for four accounts before scrolling, so a machine with many
            // logins degrades to a scroll rather than a dropdown taller than
            // the screen.
            .frame(maxHeight: 360)
```

- [ ] **Step 2: Rewrite the section and badge to take a descriptor**

Replace `providerSection(_:)` and `sourceBadge(_:)` with:

```swift
    @ViewBuilder
    private func sourceSection(_ source: SourceDescriptor) -> some View {
        let usage = model.usage[source.id] ?? .empty
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(source.displayName).font(.headline)
                sourceBadge(source.id)
            }
            if usage.windows.isEmpty {
                Text("no data").font(.caption).foregroundStyle(.secondary)
            } else {
                // Every window the source reports, however many that is —
                // dropping one is how you fail to warn about the limit that is
                // about to block you.
                ForEach(usage.windows, id: \.kind) { quota in
                    row(quota)
                }
            }
        }
    }

    /// Says plainly where a source's numbers came from, because the live and
    /// fallback sources differ in completeness — and because only the default
    /// account has a fallback at all.
    @ViewBuilder
    private func sourceBadge(_ id: SourceID) -> some View {
        switch model.sourceStatus[id] {
        case .live:
            Text("live").font(.caption2).foregroundStyle(.secondary)
        case .degraded(let how):
            Text(how).font(.caption2).foregroundStyle(.orange)
        case .unavailable(let why):
            Text(why).font(.caption2).foregroundStyle(.orange)
        case nil:
            EmptyView()
        }
    }
```

- [ ] **Step 3: Build**

Run: `tuist generate --no-open && xcodebuild -workspace TokenUsage.xcworkspace -scheme TokenUsage build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Verify by running**

Launch the app. Confirm each account gets its own section titled `Claude · <Name>`, every window is listed, the badge reads `live` for accounts that fetched, and Settings offers "One per account" with a live preview that matches the menu bar.

- [ ] **Step 5: Commit** (ask the user first)

```bash
git add App/DropdownView.swift
git commit -m "feat: list every account in the dropdown"
```

---

### Task 8: Document accounts in the README

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: everything above. Produces: nothing.

- [ ] **Step 1: Update the opening example**

The README opens with a two-provider example. Extend it to show accounts, immediately after the existing `C 47% · X 3%` block:

```markdown
With several Claude logins — the default one plus any zetty accounts — the bar
collapses Claude to whichever account is closest to a wall, so it stays the same
width however many you add:

```
C ▲ 80% · X 3%
```

Switch to **One per account** to see them side by side:

```
G 47% · W 12% · D ▲ 80% · X 3%
```
```

- [ ] **Step 2: Document discovery under "Where the numbers come from"**

Add after the **Claude — the OAuth usage API** section:

```markdown
**Claude — several accounts.** zetty runs agent panes under named accounts, each
a separate Claude login with its own config directory. Every one is tracked.

Accounts come from `zetty accounts --json` when zetty is installed, and from a
scan of `~/.zetty/accounts` for directories containing `.claude.json` when it is
not. Asking zetty matters because that folder also holds **Codex** accounts, and
only zetty knows which is which — a naive scan invents a Claude account that
reports "not signed in" forever.

Each account's credential is a separate Keychain item: `Claude Code-credentials`
for the default login, and `Claude Code-credentials-<first 8 hex of sha256 of the
config directory path>` for the rest. An account is therefore the same usage API
pointed at a different item — no new endpoint, no new parser.

macOS asks once per account before this app may read its item. The statusline
fallback covers the **default account only** — the shim lives in
`~/.claude/settings.json` and sees nothing else — so a non-default account whose
API call fails reports "last known" or "unavailable" rather than falling back.
```

- [ ] **Step 3: Update the display-modes table**

Replace the existing table with:

```markdown
| Mode | Menu bar |
|---|---|
| Worst of all windows | `● 86%` |
| One per tool (default) | `C ▲ 86% · X 1%` |
| One per account | `G 47% · W 12% · D ▲ 86% · X 1%` |
| Every window | `C ▲ 65/86/4 · X 0/1` |
```

- [ ] **Step 4: Verify the claims**

Re-read the Privacy section and confirm it is still accurate: the app now reads `~/.zetty/accounts` and `~/.claude.json`, and makes one usage call per account. Update that section if it understates either.

- [ ] **Step 5: Commit** (ask the user first)

```bash
git add README.md
git commit -m "docs: document multi-account tracking"
```

---

## Verification

Before calling this done:

- [ ] `swift test` — full core suite green.
- [ ] `tuist generate --no-open && xcodebuild -workspace TokenUsage.xcworkspace -scheme TokenUsage build` — succeeds.
- [ ] Launch and confirm every account appears with live figures.
- [ ] Confirm a machine-shaped check: temporarily rename `~/.zetty` and relaunch — the app must look exactly as it did before this work (`C … · X …`, header "Claude"). Rename it back.
- [ ] Confirm each display mode renders as the table above describes.
