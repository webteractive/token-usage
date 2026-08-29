import XCTest
@testable import TokenUsageCore

final class UsageWindowTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(
        percent: Double = 47,
        resetsIn: TimeInterval = 3600,
        observedAgo: TimeInterval = 0
    ) -> UsageWindow {
        UsageWindow(
            usedPercent: percent,
            resetsAt: now.addingTimeInterval(resetsIn),
            observedAt: now.addingTimeInterval(-observedAgo)
        )
    }

    func testFreshObservationIsLive() {
        XCTAssertEqual(window(observedAgo: 0).state(now: now), .live(47))
    }

    /// The live/stale boundary is inclusive: exactly liveWindow old is still live.
    func testObservationAtLiveBoundaryIsStillLive() {
        XCTAssertEqual(window(observedAgo: 600).state(now: now), .live(47))
    }

    func testObservationPastLiveBoundaryIsStale() {
        let since = now.addingTimeInterval(-601)
        XCTAssertEqual(window(observedAgo: 601).state(now: now), .stale(47, since: since))
    }

    /// A window whose resets_at has passed is provably empty, however old the
    /// reading is. This is what makes most staleness self-healing.
    func testPassedResetIsZeroNotStale() {
        XCTAssertEqual(window(resetsIn: -1, observedAgo: 86_400).state(now: now), .reset)
    }

    /// Reset must be checked before staleness, or an old reading of a rolled-over
    /// window reports a stale percentage that is certainly wrong.
    func testResetTakesPrecedenceOverStale() {
        let w = window(percent: 93, resetsIn: -60, observedAgo: 7200)
        XCTAssertEqual(w.state(now: now), .reset)
    }

    func testResetBoundaryIsInclusive() {
        XCTAssertEqual(window(resetsIn: 0).state(now: now), .reset)
    }

    func testPercentAccessor() {
        XCTAssertEqual(WindowState.live(47).percent, 47)
        XCTAssertEqual(WindowState.stale(12, since: now).percent, 12)
        XCTAssertEqual(WindowState.reset.percent, 0)
        XCTAssertNil(WindowState.unknown.percent)
    }

    func testStaleAndDataFlags() {
        XCTAssertTrue(WindowState.stale(1, since: now).isStale)
        XCTAssertFalse(WindowState.live(1).isStale)
        XCTAssertTrue(WindowState.reset.hasData)
        XCTAssertFalse(WindowState.unknown.hasData)
    }
}
