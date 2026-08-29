import XCTest
@testable import TokenUsageCore

final class QuotaWindowTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func w(_ pct: Double, resetsIn: TimeInterval = 3600) -> UsageWindow {
        UsageWindow(usedPercent: pct, resetsAt: now.addingTimeInterval(resetsIn), observedAt: now)
    }

    func testLabels() {
        XCTAssertEqual(WindowKind.session.label, "5h")
        XCTAssertEqual(WindowKind.weeklyAll.label, "7d")
        XCTAssertEqual(WindowKind.weeklyScoped(model: "Fable").label, "7d Fable")
        XCTAssertEqual(WindowKind.other("spend").label, "spend")
    }

    /// The list is ordered for display: session, then the all-models week, then
    /// any scoped weeks. Order must not depend on how the API happened to sort.
    func testWindowsSortIntoDisplayOrder() {
        let usage = ProviderUsage(windows: [
            QuotaWindow(kind: .weeklyScoped(model: "Fable"), window: w(4), isActive: false),
            QuotaWindow(kind: .weeklyAll, window: w(86), isActive: true),
            QuotaWindow(kind: .session, window: w(62), isActive: false),
        ])
        XCTAssertEqual(usage.windows.map(\.kind), [.session, .weeklyAll, .weeklyScoped(model: "Fable")])
    }

    /// The whole point of generalising: a scoped weekly window must be able to
    /// win. Missing this is what made the app under-report.
    func testDominantConsidersScopedWindows() {
        let usage = ProviderUsage(windows: [
            QuotaWindow(kind: .session, window: w(10), isActive: false),
            QuotaWindow(kind: .weeklyAll, window: w(20), isActive: false),
            QuotaWindow(kind: .weeklyScoped(model: "Fable"), window: w(97), isActive: true),
        ])
        XCTAssertEqual(usage.dominant(now: now), .live(97))
    }

    func testEmptyUsageIsUnknown() {
        XCTAssertEqual(ProviderUsage.empty.dominant(now: now), .unknown)
    }

    func testLookupByKind() {
        let usage = ProviderUsage(windows: [
            QuotaWindow(kind: .session, window: w(62), isActive: false),
            QuotaWindow(kind: .weeklyAll, window: w(86), isActive: true),
        ])
        XCTAssertEqual(usage.window(.session)?.window.usedPercent, 62)
        XCTAssertEqual(usage.window(.weeklyAll)?.window.usedPercent, 86)
        XCTAssertNil(usage.window(.weeklyScoped(model: "Fable")))
    }

    /// A reset window counts as 0 and must not beat a live reading.
    func testResetWindowLosesToLiveReading() {
        let usage = ProviderUsage(windows: [
            QuotaWindow(kind: .session, window: w(99, resetsIn: -1), isActive: false),
            QuotaWindow(kind: .weeklyAll, window: w(12), isActive: false),
        ])
        XCTAssertEqual(usage.dominant(now: now), .live(12))
    }
}
