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

        XCTAssertEqual(usage.fiveHour?.usedPercent, 47)
        XCTAssertEqual(usage.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_787_845_497))
        XCTAssertEqual(usage.fiveHour?.observedAt, observedAt)

        XCTAssertEqual(usage.sevenDay?.usedPercent, 31)
        XCTAssertEqual(usage.sevenDay?.resetsAt, Date(timeIntervalSince1970: 1_788_333_028))
    }

    /// rate_limits is documented as subscriber-only. Its absence is a normal
    /// state, not a parse error — and must not become a zero.
    func testAbsentRateLimitsYieldsEmptyNotZero() throws {
        let usage = try ClaudeStatuslineParser.parse(fixture("claude-no-rate-limits"), observedAt: observedAt)
        XCTAssertNil(usage.fiveHour)
        XCTAssertNil(usage.sevenDay)
        XCTAssertEqual(usage.dominant(now: observedAt), .unknown)
    }

    func testPartialRateLimitsKeepsPresentWindow() throws {
        let json = #"{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1787845497}}}"#
        let usage = try ClaudeStatuslineParser.parse(Data(json.utf8), observedAt: observedAt)
        XCTAssertEqual(usage.fiveHour?.usedPercent, 12)
        XCTAssertNil(usage.sevenDay)
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(
            try ClaudeStatuslineParser.parse(Data("not json".utf8), observedAt: observedAt)
        )
    }
}
