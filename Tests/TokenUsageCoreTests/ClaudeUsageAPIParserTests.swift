import XCTest
@testable import TokenUsageCore

final class ClaudeUsageAPIParserTests: XCTestCase {

    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
        )
        return try Data(contentsOf: url)
    }

    func testParsesEveryWindowIncludingScoped() throws {
        let usage = try ClaudeUsageAPIParser.parse(fixture("claude-api-usage"), observedAt: observedAt)

        XCTAssertEqual(usage.windows.map(\.kind), [
            .session, .weeklyAll, .weeklyScoped(model: "Fable"),
        ])
        XCTAssertEqual(usage.window(.session)?.window.usedPercent, 62)
        XCTAssertEqual(usage.window(.weeklyAll)?.window.usedPercent, 86)
        XCTAssertEqual(usage.window(.weeklyScoped(model: "Fable"))?.window.usedPercent, 4)
    }

    /// The window the statusline could never see. Its absence was a real
    /// under-report, so this is the regression that matters.
    func testScopedWeeklyWindowIsPresent() throws {
        let usage = try ClaudeUsageAPIParser.parse(fixture("claude-api-usage"), observedAt: observedAt)
        XCTAssertNotNil(usage.window(.weeklyScoped(model: "Fable")))
    }

    func testParsesISO8601ResetsWithFractionalSecondsAndOffset() throws {
        let usage = try ClaudeUsageAPIParser.parse(fixture("claude-api-usage"), observedAt: observedAt)
        let reset = try XCTUnwrap(usage.window(.session)?.window.resetsAt)
        // 2026-08-29T05:39:59.548066+00:00
        XCTAssertEqual(reset.timeIntervalSince1970, 1_787_981_999.548, accuracy: 1)
    }

    func testCarriesActiveFlag() throws {
        let usage = try ClaudeUsageAPIParser.parse(fixture("claude-api-usage"), observedAt: observedAt)
        XCTAssertEqual(usage.window(.weeklyAll)?.isActive, true)
        XCTAssertEqual(usage.window(.session)?.isActive, false)
    }

    /// A limit the API adds later must not be dropped silently, nor crash the
    /// parse — the list is open-ended by design.
    func testUnknownKindIsKeptAsOther() throws {
        let json = #"""
        {"limits":[{"kind":"monthly_experiment","group":"other","percent":12,
          "resets_at":"2026-09-01T00:00:00.000000+00:00","scope":null,"is_active":false}]}
        """#
        let usage = try ClaudeUsageAPIParser.parse(Data(json.utf8), observedAt: observedAt)
        XCTAssertEqual(usage.windows.map(\.kind), [.other("monthly_experiment")])
        XCTAssertEqual(usage.windows.first?.window.usedPercent, 12)
    }

    func testMissingLimitsArrayYieldsEmpty() throws {
        let usage = try ClaudeUsageAPIParser.parse(Data("{}".utf8), observedAt: observedAt)
        XCTAssertEqual(usage, .empty)
    }

    /// A window with no resets_at cannot drive a countdown and is skipped
    /// rather than given a fabricated one.
    func testWindowWithoutResetIsSkipped() throws {
        let json = #"{"limits":[{"kind":"session","percent":5,"resets_at":null,"is_active":false}]}"#
        let usage = try ClaudeUsageAPIParser.parse(Data(json.utf8), observedAt: observedAt)
        XCTAssertEqual(usage, .empty)
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try ClaudeUsageAPIParser.parse(Data("nope".utf8), observedAt: observedAt))
    }
}
