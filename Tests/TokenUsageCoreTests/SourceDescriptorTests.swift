import XCTest
@testable import TokenUsageCore

final class SourceDescriptorTests: XCTestCase {

    private func account(_ id: String, _ name: String?) -> ClaudeAccount {
        ClaudeAccount(
            id: id,
            directory: URL(fileURLWithPath: "/Users/example/.zetty/accounts/\(id)"),
            owner: .zetty,
            displayName: name
        )
    }

    private func tinkerAccount(_ name: String?) -> ClaudeAccount {
        ClaudeAccount(
            id: ClaudeAccount.tinkerID,
            directory: URL(fileURLWithPath: "/Users/example/Library/Application Support/Tinker/claude"),
            owner: .tinker,
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

        // The heading says whose login a row is, so only the account is named.
        XCTAssertEqual(sources.map(\.displayName), ["Claude", "Devops", "Warda", "Codex"])
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

        XCTAssertEqual(sources[1].displayName, "Fresh")
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

    /// Both clamps in the short-label loop are load-bearing: an empty names
    /// array and an array of empty names are different inputs, and the second
    /// would make the range 1...0 and trap.
    func testAccountsWithEmptyNamesDoNotTrap() {
        let blank = ClaudeAccount(
            id: "",
            directory: URL(fileURLWithPath: "/Users/example/.zetty/accounts/blank"),
            displayName: ""
        )
        let sources = SourceCatalog.descriptors(claudeAccounts: [blank, blank])

        XCTAssertEqual(sources.count, 3)
        XCTAssertEqual(SourceCatalog.shortLabels(for: []), [])
        XCTAssertEqual(SourceCatalog.shortLabels(for: ["", ""]).count, 2)
    }

    // MARK: - Sections

    /// Default holds the tools' own logins, then one heading per tool that
    /// keeps accounts of its own.
    func testRowsAreListedUnderTheToolTheyBelongTo() {
        let sections = SourceCatalog.sections(SourceCatalog.descriptors(claudeAccounts: [
            defaultAccount("Glen"),
            account("devops", "Devops"),
            account("warda", "Warda"),
            tinkerAccount("Acme"),
        ]))

        XCTAssertEqual(sections.map(\.title), ["Default", "Zetty", "Tinker"])
        XCTAssertEqual(
            sections.map { $0.sources.map(\.displayName) },
            [["Claude", "Codex"], ["Devops", "Warda"], ["Acme"]]
        )
    }

    /// Codex sits beside the default Claude login in the dropdown, yet keeps
    /// its place at the end of the menu bar.
    func testGroupingDoesNotReorderTheMenuBar() {
        let sources = SourceCatalog.descriptors(claudeAccounts: [
            defaultAccount("Glen"), account("devops", "Devops"), tinkerAccount("Acme"),
        ])

        XCTAssertEqual(sources.map(\.shortLabel), ["G", "D", "A", "X"])
        XCTAssertEqual(SourceCatalog.sections(sources).first?.sources.map(\.id), [.claude("default"), .codex])
    }

    func testAMachineWithNoOtherToolsHasOneSection() {
        let sections = SourceCatalog.sections(
            SourceCatalog.descriptors(claudeAccounts: [defaultAccount("Glen")])
        )

        XCTAssertEqual(sections.map(\.title), ["Default"])
    }

    func testNoSourcesMeansNoSections() {
        XCTAssertEqual(SourceCatalog.sections([]), [])
    }
}
