import XCTest
@testable import TokenUsageCore

final class CountdownFormatterTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(resetsIn: TimeInterval, observedAgo: TimeInterval = 0) -> UsageWindow {
        UsageWindow(
            usedPercent: 10,
            resetsAt: now.addingTimeInterval(resetsIn),
            observedAt: now.addingTimeInterval(-observedAgo)
        )
    }

    func testFormatsHoursAndMinutes() {
        XCTAssertEqual(CountdownFormatter.reset(for: window(resetsIn: 8040), now: now), "resets in 2h 14m")
    }

    func testFormatsMinutesOnly() {
        XCTAssertEqual(CountdownFormatter.reset(for: window(resetsIn: 600), now: now), "resets in 10m")
    }

    func testFormatsDaysAndHours() {
        XCTAssertEqual(CountdownFormatter.reset(for: window(resetsIn: 356_400), now: now), "resets in 4d 3h")
    }

    /// A passed reset is the good case — say so plainly rather than showing a
    /// negative countdown.
    func testPassedResetReadsAsElapsed() {
        XCTAssertEqual(CountdownFormatter.reset(for: window(resetsIn: -10_800), now: now), "window reset 3h ago")
    }

    func testMissingWindowHasNoCountdown() {
        XCTAssertEqual(CountdownFormatter.reset(for: nil, now: now), "no data")
    }

    func testObservedTextOnlyForStaleReadings() {
        XCTAssertNil(CountdownFormatter.observed(.live(47)))
        XCTAssertNil(CountdownFormatter.observed(.reset))
        let since = Date(timeIntervalSince1970: 1_787_845_000)
        XCTAssertNotNil(CountdownFormatter.observed(.stale(47, since: since)))
        XCTAssertTrue(CountdownFormatter.observed(.stale(47, since: since))!.hasPrefix("as of "))
    }
}
