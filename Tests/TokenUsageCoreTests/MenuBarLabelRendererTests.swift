import XCTest
@testable import TokenUsageCore

final class MenuBarLabelRendererTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(
        _ percent: Double,
        resetsIn: TimeInterval = 3600,
        observedAgo: TimeInterval = 0
    ) -> UsageWindow {
        UsageWindow(
            usedPercent: percent,
            resetsAt: now.addingTimeInterval(resetsIn),
            observedAt: now.addingTimeInterval(-observedAgo)
        )
    }

    /// Builds the common session + weekly pair the old two-field model implied.
    private func pair(session: UsageWindow?, weekly: UsageWindow?) -> ProviderUsage {
        ProviderUsage(windows: [
            session.map { QuotaWindow(kind: .session, window: $0, isActive: false) },
            weekly.map { QuotaWindow(kind: .weeklyAll, window: $0, isActive: false) },
        ].compactMap { $0 })
    }

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
        accounts: [ClaudeAccount]? = nil,
        hidingEmpty: Bool = false
    ) -> LabelSpec {
        MenuBarLabelRenderer.render(
            usage: u,
            sources: SourceCatalog.descriptors(claudeAccounts: accounts ?? soleAccount),
            mode: mode,
            thresholds: .default,
            hidesEmptySources: hidingEmpty,
            now: now
        )
    }

    func testWorstOfShowsHighestAcrossBothProviders() {
        let segs = render(.worstOf, sample)
        XCTAssertEqual(segs.map(\.text), ["● 47%"])
        XCTAssertEqual(segs[0].severity, .normal)
    }

    func testPerToolShowsEachProvidersDominantWindow() {
        let segs = render(.perTool, sample)
        XCTAssertEqual(segs.map(\.text), ["C 47%", "X 3%"])
    }

    func testFullShowsAllFourAsPairs() {
        let segs = render(.full, sample)
        XCTAssertEqual(segs.map(\.text), ["C 47/31", "X 3/1"])
    }



    /// Non-normal severity adds its shape marker in the per-tool mode; normal
    /// stays clean so the common case is not noisy.
    func testSeverityMarkersAppearInPerTool() {
        let u = usage(
            claude: pair(session: window(78), weekly: nil),
            codex: pair(session: window(93), weekly: nil)
        )
        let segs = render(.perTool, u)
        XCTAssertEqual(segs.map(\.text), ["C ▲ 78%", "X ■ 93%"])
        XCTAssertEqual(segs[0].severity, .warning)
        XCTAssertEqual(segs[1].severity, .critical)
    }

    /// Worst-of always carries a marker, since the marker is that mode's
    /// identity glyph as well as its severity cue.
    func testWorstOfMarkerTracksSeverity() {
        let u = usage(claude: pair(session: window(93), weekly: nil), codex: .empty)
        let segs = render(.worstOf, u)
        XCTAssertEqual(segs.map(\.text), ["■ 93%"])
    }

    func testStaleReadingIsPrefixedAndFlagged() {
        let u = usage(
            claude: pair(session: window(47, observedAgo: 3600), weekly: nil),
            codex: .empty
        )
        let segs = render(.perTool, u)
        XCTAssertEqual(segs[0].text, "C ‹47%")
        XCTAssertTrue(segs[0].isStale)
    }

    /// "No data" and "no usage" are different claims. A provider that never
    /// reported must never render as 0%.
    func testNoDataRendersEmDashNotZero() {
        let u = usage(claude: .empty, codex: pair(session: window(3), weekly: nil))
        let segs = render(.perTool, u)
        XCTAssertEqual(segs.map(\.text), ["C —", "X 3%"])
        XCTAssertFalse(segs[0].hasData)
    }

    /// A reset window is known to be empty, so 0% here is a real claim.
    func testResetWindowRendersZero() {
        let u = usage(
            claude: pair(session: window(47, resetsIn: -1), weekly: nil),
            codex: .empty
        )
        let segs = render(.perTool, u)
        XCTAssertEqual(segs[0].text, "C 0%")
        XCTAssertTrue(segs[0].hasData)
    }

    func testPercentagesRoundToWholeNumbers() {
        let u = usage(claude: pair(session: window(47.6), weekly: nil), codex: .empty)
        let segs = render(.perTool, u)
        XCTAssertEqual(segs[0].text, "C 48%")
    }

    func testProviderOrderIsAlwaysClaudeThenCodex() {
        let segs = render(.perTool, sample)
        XCTAssertTrue(segs[0].text.hasPrefix("C"))
        XCTAssertTrue(segs[1].text.hasPrefix("X"))
    }

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

        XCTAssertEqual(segs.map(\.text), ["C \u{25B2} 80%", "X 3%"])
        XCTAssertEqual(segs[0].severity, .warning)
    }

    func testPerAccountShowsEverySourceSeparately() {
        let segs = render(.perAccount, multiAccountSample, accounts: threeAccounts)

        XCTAssertEqual(segs.map(\.text), ["G 47%", "D \u{25B2} 80%", "W 12%", "X 3%"])
    }

    func testPerAccountWithOneAccountMatchesPerTool() {
        XCTAssertEqual(
            render(.perAccount, sample).map(\.text),
            render(.perTool, sample).map(\.text)
        )
    }

    func testWorstOfSpansAccounts() {
        let segs = render(.worstOf, multiAccountSample, accounts: threeAccounts)

        XCTAssertEqual(segs.map(\.text), ["\u{25B2} 80%"])
    }

    func testFullShowsEveryWindowOfEverySource() {
        let segs = render(.full, multiAccountSample, accounts: threeAccounts)

        XCTAssertEqual(segs.map(\.text), ["G 47/31", "D \u{25B2} 80/64", "W 12/8", "X 3/1"])
    }

    func testAccountWithNoDataRendersEmDashNeverZero() {
        var partial = multiAccountSample
        partial[.claude("warda")] = .empty
        let segs = render(.perAccount, partial, accounts: threeAccounts)

        XCTAssertEqual(segs[2].text, "W \u{2014}")
        XCTAssertFalse(segs[2].hasData)
    }

    func testEveryWindowModeIsNamedForWhatItShows() {
        XCTAssertEqual(DisplayMode.full.title, "Every window")
        XCTAssertEqual(DisplayMode.perAccount.title, "One per account")
    }

    // MARK: - Hiding sources with nothing to report

    /// An account that has never reported is noise in a space this small. The
    /// dropdown still lists it, badge and all, so nothing is actually hidden.
    func testHidesSourcesWithoutDataInPerAccount() {
        var partial = multiAccountSample
        partial[.claude("devops")] = .empty
        let segs = render(.perAccount, partial, accounts: threeAccounts, hidingEmpty: true)

        XCTAssertEqual(segs.map(\.text), ["G 47%", "W 12%", "X 3%"])
    }

    func testHidesSourcesWithoutDataInEveryWindow() {
        var partial = multiAccountSample
        partial[.claude("devops")] = .empty
        let segs = render(.full, partial, accounts: threeAccounts, hidingEmpty: true)

        XCTAssertEqual(segs.map(\.text), ["G 47/31", "W 12/8", "X 3/1"])
    }

    /// An empty menu bar item would be invisible and unclickable, so a machine
    /// where nothing has reported still shows a single em dash.
    func testShowsOneEmDashWhenNothingHasData() {
        let empty: [SourceID: ProviderUsage] = [:]
        let segs = render(.perAccount, empty, accounts: threeAccounts, hidingEmpty: true)

        XCTAssertEqual(segs.map(\.text), ["—"])
        XCTAssertFalse(segs[0].hasData)
    }

    /// Off, the em dash comes back: "never reported" stays visible for anyone
    /// who wants to see it.
    func testFilterOffKeepsSilentSources() {
        var partial = multiAccountSample
        partial[.claude("devops")] = .empty
        let segs = render(.perAccount, partial, accounts: threeAccounts, hidingEmpty: false)

        XCTAssertEqual(segs.map(\.text), ["G 47%", "D —", "W 12%", "X 3%"])
    }

    /// One per tool is untouched: a whole vendor going quiet is worth saying out
    /// loud, unlike one login among several.
    func testPerToolStillReportsASilentProvider() {
        let u = usage(claude: .empty, codex: pair(session: window(3), weekly: nil))
        let segs = render(.perTool, u, hidingEmpty: true)

        XCTAssertEqual(segs.map(\.text), ["C —", "X 3%"])
    }
}
