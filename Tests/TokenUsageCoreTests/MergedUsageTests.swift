import XCTest
@testable import TokenUsageCore

final class MergedUsageTests: XCTestCase {

    private let reset = Date(timeIntervalSince1970: 1_791_702_000)
    private let now = Date(timeIntervalSince1970: 1_791_650_000)

    private func reading(
        _ kind: WindowKind,
        _ percent: Double,
        resetsAt: Date? = nil,
        observedAgo: TimeInterval = 0,
        isActive: Bool = false
    ) -> ProviderUsage {
        ProviderUsage(windows: [
            QuotaWindow(
                kind: kind,
                window: UsageWindow(
                    usedPercent: percent,
                    resetsAt: resetsAt ?? reset,
                    observedAt: now.addingTimeInterval(-observedAgo)
                ),
                isActive: isActive
            ),
        ])
    }

    /// The case that started this: seven sessions of one login, each repeating
    /// the figure from its own last request. The one that rendered last said
    /// 19 while the login stood at 75.
    func testHighestReadingOfAWindowWinsWhateverItsAge() {
        let merged = ProviderUsage.merged([
            reading(.weeklyAll, 75, observedAgo: 3600),
            reading(.weeklyAll, 54, observedAgo: 60),
            reading(.weeklyAll, 19, observedAgo: 1),
        ])

        XCTAssertEqual(merged.window(.weeklyAll)?.window.usedPercent, 75)
    }

    /// A reading for a window that has since reset says nothing about the
    /// current one, however high it got.
    func testLaterWindowReplacesAnEarlierOne() {
        let merged = ProviderUsage.merged([
            reading(.session, 98, resetsAt: reset),
            reading(.session, 4, resetsAt: reset.addingTimeInterval(5 * 3600)),
        ])

        XCTAssertEqual(merged.window(.session)?.window.usedPercent, 4)
        XCTAssertEqual(merged.window(.session)?.window.resetsAt, reset.addingTimeInterval(5 * 3600))
    }

    /// The API reports a reset of 05:59:59.58 where the statusline reports
    /// 06:00:00. Those are one window, not two.
    func testResetsAFractionApartAreTheSameWindow() {
        let merged = ProviderUsage.merged([
            reading(.weeklyAll, 75, resetsAt: reset.addingTimeInterval(-0.42)),
            reading(.weeklyAll, 19, resetsAt: reset),
        ])

        XCTAssertEqual(merged.window(.weeklyAll)?.window.usedPercent, 75)
    }

    /// The statusline rounds to whole percents, so its 75 outranks a newer
    /// 74.6 from the API. The newer reading still confirms it, and the result
    /// must not be dimmed as old.
    func testAgreeingReadingRefreshesTheWinner() {
        let merged = ProviderUsage.merged([
            reading(.weeklyAll, 75, observedAgo: 7200),
            reading(.weeklyAll, 74.6, observedAgo: 30),
        ])

        let window = try? XCTUnwrap(merged.window(.weeklyAll)?.window)
        XCTAssertEqual(window?.usedPercent, 75)
        XCTAssertEqual(window?.observedAt, now.addingTimeInterval(-30))
    }

    func testLowerReadingDoesNotRefreshTheWinner() {
        let merged = ProviderUsage.merged([
            reading(.weeklyAll, 75, observedAgo: 7200),
            reading(.weeklyAll, 19, observedAgo: 30),
        ])

        XCTAssertEqual(merged.window(.weeklyAll)?.window.observedAt, now.addingTimeInterval(-7200))
    }

    /// The scoped weekly limits come only from the API and the 5-hour window
    /// often only from a session, so limits are merged one by one.
    func testKeepsLimitsThatOnlyOneReadingCarries() {
        let merged = ProviderUsage.merged([
            reading(.session, 21),
            reading(.weeklyScoped(model: "Fable"), 40),
        ])

        XCTAssertEqual(merged.windows.map(\.kind), [.session, .weeklyScoped(model: "Fable")])
    }

    func testKeepsTheActiveFlagOfTheWindow() {
        let merged = ProviderUsage.merged([
            reading(.session, 20, isActive: true),
            reading(.session, 21),
        ])

        XCTAssertEqual(merged.window(.session)?.isActive, true)
    }

    func testNothingMergesToNothing() {
        XCTAssertEqual(ProviderUsage.merged([]), .empty)
        XCTAssertEqual(ProviderUsage.merged([.empty, .empty]), .empty)
    }
}
