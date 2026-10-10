import XCTest
@testable import TokenUsageCore

final class TinkerUsageParserTests: XCTestCase {

    private let modifiedAt = Date(timeIntervalSince1970: 1_791_650_000)

    /// The shape Tinker 0.1.10 writes while only the weekly window is known.
    func testParsesTheWeeklyWindow() throws {
        let json = #"{"snapshot":{"sevenDay":{"resetsAt":1792216800,"usedPercentage":2}},"updatedAt":1791643779.46385}"#
        let usage = try TinkerUsageParser.parse(Data(json.utf8), modifiedAt: modifiedAt)

        XCTAssertEqual(usage.windows.map(\.kind), [.weeklyAll])
        XCTAssertEqual(usage.window(.weeklyAll)?.window.usedPercent, 2)
        XCTAssertEqual(usage.window(.weeklyAll)?.window.resetsAt, Date(timeIntervalSince1970: 1_792_216_800))
    }

    func testParsesBothWindows() throws {
        let json = """
        {"snapshot":{"fiveHour":{"resetsAt":1791660600,"usedPercentage":4},
        "sevenDay":{"resetsAt":1792216800,"usedPercentage":3}},"updatedAt":1791643779}
        """
        let usage = try TinkerUsageParser.parse(Data(json.utf8), modifiedAt: modifiedAt)

        XCTAssertEqual(usage.window(.session)?.window.usedPercent, 4)
        XCTAssertEqual(usage.window(.weeklyAll)?.window.usedPercent, 3)
    }

    /// The file says when the reading was taken, which is not when it was
    /// last touched.
    func testDatesTheReadingByTheFilesOwnTimestamp() throws {
        let json = #"{"snapshot":{"sevenDay":{"resetsAt":1792216800,"usedPercentage":2}},"updatedAt":1791643779.5}"#
        let usage = try TinkerUsageParser.parse(Data(json.utf8), modifiedAt: modifiedAt)

        XCTAssertEqual(
            usage.window(.weeklyAll)?.window.observedAt,
            Date(timeIntervalSince1970: 1_791_643_779.5)
        )
    }

    func testFallsBackToTheModificationDate() throws {
        let json = #"{"snapshot":{"sevenDay":{"resetsAt":1792216800,"usedPercentage":2}}}"#
        let usage = try TinkerUsageParser.parse(Data(json.utf8), modifiedAt: modifiedAt)

        XCTAssertEqual(usage.window(.weeklyAll)?.window.observedAt, modifiedAt)
    }

    /// No snapshot yet is "no data", never zero usage.
    func testMissingSnapshotIsEmpty() throws {
        XCTAssertEqual(try TinkerUsageParser.parse(Data("{}".utf8), modifiedAt: modifiedAt), .empty)
        XCTAssertEqual(
            try TinkerUsageParser.parse(Data(#"{"snapshot":{}}"#.utf8), modifiedAt: modifiedAt),
            .empty
        )
    }

    func testMalformedFileThrows() {
        XCTAssertThrowsError(try TinkerUsageParser.parse(Data("not json".utf8), modifiedAt: modifiedAt))
    }
}
