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
