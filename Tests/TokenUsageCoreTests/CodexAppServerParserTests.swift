import XCTest
@testable import TokenUsageCore

final class CodexAppServerParserTests: XCTestCase {

    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/codex-ratelimits", withExtension: "json")
        )
        return try Data(contentsOf: url)
    }

    func testParsesMainBucketAsSessionAndWeekly() throws {
        let usage = try CodexAppServerParser.parse(fixture(), observedAt: observedAt)
        XCTAssertEqual(usage.window(.session)?.window.usedPercent, 6)
        XCTAssertEqual(usage.window(.session)?.window.resetsAt, Date(timeIntervalSince1970: 1_787_996_507))
        XCTAssertEqual(usage.window(.weeklyAll)?.window.usedPercent, 1)
    }

    /// Codex has a scoped bucket the rollout files never contain — the same
    /// class of blind spot that hid Claude's Fable window.
    func testParsesScopedBucket() throws {
        let usage = try CodexAppServerParser.parse(fixture(), observedAt: observedAt)
        let scoped = try XCTUnwrap(usage.window(.weeklyScoped(model: "gpt-reserve")))
        XCTAssertEqual(scoped.window.usedPercent, 0)
        XCTAssertEqual(scoped.window.resetsAt, Date(timeIntervalSince1970: 1_788_583_592))
    }

    func testWindowsAreInDisplayOrder() throws {
        let usage = try CodexAppServerParser.parse(fixture(), observedAt: observedAt)
        XCTAssertEqual(usage.windows.map(\.kind),
                       [.session, .weeklyAll, .weeklyScoped(model: "gpt-reserve")])
    }

    /// A bucket with no limitName should still be identifiable.
    func testScopedBucketFallsBackToLimitId() throws {
        let json = #"""
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":100}},
         "rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":100}},
           "mystery":{"limitId":"mystery","primary":{"usedPercent":9,"windowDurationMins":10080,"resetsAt":200}}}}
        """#
        let usage = try CodexAppServerParser.parse(Data(json.utf8), observedAt: observedAt)
        XCTAssertEqual(usage.window(.weeklyScoped(model: "mystery"))?.window.usedPercent, 9)
    }

    /// Older responses carry only the single-bucket view.
    func testFallsBackToSingleBucketWhenByLimitIdAbsent() throws {
        let json = #"""
        {"rateLimits":{"limitId":"codex",
          "primary":{"usedPercent":6,"windowDurationMins":300,"resetsAt":100},
          "secondary":{"usedPercent":1,"windowDurationMins":10080,"resetsAt":200}}}
        """#
        let usage = try CodexAppServerParser.parse(Data(json.utf8), observedAt: observedAt)
        XCTAssertEqual(usage.window(.session)?.window.usedPercent, 6)
        XCTAssertEqual(usage.window(.weeklyAll)?.window.usedPercent, 1)
    }

    /// A window with no resetsAt cannot drive a countdown.
    func testWindowWithoutResetIsSkipped() throws {
        let json = #"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":6,"windowDurationMins":300}}}"#
        let usage = try CodexAppServerParser.parse(Data(json.utf8), observedAt: observedAt)
        XCTAssertEqual(usage, .empty)
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try CodexAppServerParser.parse(Data("nope".utf8), observedAt: observedAt))
    }
}
