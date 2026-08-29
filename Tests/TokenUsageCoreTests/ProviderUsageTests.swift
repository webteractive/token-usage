import XCTest
@testable import TokenUsageCore

final class ProviderUsageTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ percent: Double, resetsIn: TimeInterval = 3600) -> UsageWindow {
        UsageWindow(
            usedPercent: percent,
            resetsAt: now.addingTimeInterval(resetsIn),
            observedAt: now
        )
    }

    /// The nearest wall is the one worth showing, so the higher window wins —
    /// not the 5-hour one by default.
    func testDominantPicksHigherWindow() {
        let usage = ProviderUsage(fiveHour: window(31), sevenDay: window(47))
        XCTAssertEqual(usage.dominant(now: now), .live(47))
    }

    func testDominantPicksFiveHourWhenHigher() {
        let usage = ProviderUsage(fiveHour: window(80), sevenDay: window(12))
        XCTAssertEqual(usage.dominant(now: now), .live(80))
    }

    /// A reset window counts as 0%, so it must not beat a real reading.
    func testResetWindowLosesToLiveReading() {
        let usage = ProviderUsage(fiveHour: window(0, resetsIn: -1), sevenDay: window(12))
        XCTAssertEqual(usage.dominant(now: now), .live(12))
    }

    func testMissingWindowIsIgnored() {
        let usage = ProviderUsage(fiveHour: nil, sevenDay: window(12))
        XCTAssertEqual(usage.dominant(now: now), .live(12))
    }

    func testNoWindowsIsUnknown() {
        XCTAssertEqual(ProviderUsage(fiveHour: nil, sevenDay: nil).dominant(now: now), .unknown)
    }

    func testProviderLabels() {
        XCTAssertEqual(Provider.claude.shortLabel, "C")
        XCTAssertEqual(Provider.codex.shortLabel, "X")
        XCTAssertEqual(Provider.claude.displayName, "Claude")
        XCTAssertEqual(Provider.codex.displayName, "Codex")
    }
}
