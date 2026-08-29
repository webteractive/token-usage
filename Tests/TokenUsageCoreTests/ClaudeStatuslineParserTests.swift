import XCTest
@testable import TokenUsageCore

final class ClaudeStatuslineParserTests: XCTestCase {

    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
        )
        return try Data(contentsOf: url)
    }

    func testParsesBothWindows() throws {
        let usage = try ClaudeStatuslineParser.parse(fixture("claude-statusline"), observedAt: observedAt)

        XCTAssertEqual(usage.window(.session)?.window.usedPercent, 47)
        XCTAssertEqual(usage.window(.session)?.window.resetsAt, Date(timeIntervalSince1970: 1_787_845_497))
        XCTAssertEqual(usage.window(.session)?.window.observedAt, observedAt)

        XCTAssertEqual(usage.window(.weeklyAll)?.window.usedPercent, 31)
        XCTAssertEqual(usage.window(.weeklyAll)?.window.resetsAt, Date(timeIntervalSince1970: 1_788_333_028))
    }

    /// rate_limits is documented as subscriber-only. Its absence is a normal
    /// state, not a parse error — and must not become a zero.
    func testAbsentRateLimitsYieldsEmptyNotZero() throws {
        let usage = try ClaudeStatuslineParser.parse(fixture("claude-no-rate-limits"), observedAt: observedAt)
        XCTAssertNil(usage.window(.session))
        XCTAssertNil(usage.window(.weeklyAll))
        XCTAssertEqual(usage.dominant(now: observedAt), .unknown)
    }

    func testPartialRateLimitsKeepsPresentWindow() throws {
        let json = #"{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1787845497}}}"#
        let usage = try ClaudeStatuslineParser.parse(Data(json.utf8), observedAt: observedAt)
        XCTAssertEqual(usage.window(.session)?.window.usedPercent, 12)
        XCTAssertNil(usage.window(.weeklyAll))
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(
            try ClaudeStatuslineParser.parse(Data("not json".utf8), observedAt: observedAt)
        )
    }
}
