import XCTest
@testable import TokenUsageCore

final class CodexRolloutParserTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: ext)
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParsesLastReadingSkippingTruncatedFirstLine() throws {
        let usage = try XCTUnwrap(CodexRolloutParser.parseLatest(chunk: fixture("codex-tail", "jsonl")))

        // 3.0 is from the final line; 2.0 from the earlier one must not win.
        XCTAssertEqual(usage.window(.session)?.window.usedPercent, 3)
        XCTAssertEqual(usage.window(.session)?.window.resetsAt, Date(timeIntervalSince1970: 1_787_845_497))
        XCTAssertEqual(usage.window(.weeklyAll)?.window.usedPercent, 1)
        XCTAssertEqual(usage.window(.weeklyAll)?.window.resetsAt, Date(timeIntervalSince1970: 1_788_333_028))
    }

    /// observedAt comes from the line's own timestamp, which is more accurate
    /// than the file's mtime when a session wrote later non-usage events.
    func testObservedAtComesFromLineTimestamp() throws {
        let usage = try XCTUnwrap(CodexRolloutParser.parseLatest(chunk: fixture("codex-tail", "jsonl")))
        let expected = ISO8601DateFormatter.codexParser.date(from: "2026-08-27T10:51:47.735Z")
        XCTAssertEqual(usage.window(.session)?.window.observedAt, expected)
    }

    func testChunkWithoutRateLimitsReturnsNil() {
        let chunk = #"{"timestamp":"2026-08-27T10:50:00.000Z","type":"event_msg","payload":{"type":"agent_message"}}"#
        XCTAssertNil(CodexRolloutParser.parseLatest(chunk: chunk))
    }

    func testEmptyChunkReturnsNil() {
        XCTAssertNil(CodexRolloutParser.parseLatest(chunk: ""))
    }

    /// A chunk that is one truncated line has no complete record to read.
    func testOnlyTruncatedLineReturnsNil() {
        XCTAssertNil(CodexRolloutParser.parseLatest(chunk: #"_tokens":1883}}}}"#))
    }
}
