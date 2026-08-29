import XCTest
@testable import TokenUsageCore

final class CodexCollectorTests: XCTestCase {

    private var home: URL!
    private var paths: Paths!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tokenusage-codex-\(UUID().uuidString)")
        paths = Paths(home: home)
        try FileManager.default.createDirectory(
            at: paths.codexSessions.appendingPathComponent("2026/08/27"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    private func writeRollout(_ name: String, percent: Double, modified: Date) throws -> URL {
        let url = paths.codexSessions
            .appendingPathComponent("2026/08/27")
            .appendingPathComponent(name)
        let lines = """
        {"timestamp":"2026-08-27T10:50:00.000Z","type":"event_msg","payload":{"type":"agent_message"}}
        {"timestamp":"2026-08-27T10:51:47.735Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":\(percent),"window_minutes":300,"resets_at":1787845497},"secondary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1788333028}}}}
        """
        try Data(lines.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func testNewestRolloutWinsRegardlessOfName() throws {
        try writeRollout("rollout-2026-08-27T09-00-00-aaa.jsonl", percent: 9, modified: Date(timeIntervalSince1970: 1000))
        try writeRollout("rollout-2026-08-27T08-00-00-bbb.jsonl", percent: 42, modified: Date(timeIntervalSince1970: 9000))

        let collector = CodexCollector(paths: paths)
        // Quota is account-wide, so recency decides, not the name's timestamp.
        XCTAssertEqual(collector.collect()?.window(.session)?.window.usedPercent, 42)
    }

    func testCollectReadsBothWindows() throws {
        try writeRollout("rollout-a.jsonl", percent: 3, modified: Date())
        let usage = try XCTUnwrap(CodexCollector(paths: paths).collect())
        XCTAssertEqual(usage.window(.session)?.window.usedPercent, 3)
        XCTAssertEqual(usage.window(.weeklyAll)?.window.usedPercent, 1)
    }

    func testNoSessionsDirectoryReturnsNil() {
        let empty = Paths(home: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        XCTAssertNil(CodexCollector(paths: empty).collect())
    }

    func testDirectoryWithNoRolloutsReturnsNil() {
        XCTAssertNil(CodexCollector(paths: paths).collect())
    }

    func testIgnoresNonRolloutFiles() throws {
        let stray = paths.codexSessions.appendingPathComponent("2026/08/27/notes.txt")
        try Data("hello".utf8).write(to: stray)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 99_999)], ofItemAtPath: stray.path
        )
        try writeRollout("rollout-a.jsonl", percent: 7, modified: Date(timeIntervalSince1970: 1000))

        XCTAssertEqual(CodexCollector(paths: paths).collect()?.window(.session)?.window.usedPercent, 7)
    }

    /// A small tail can land past the last reading; the collector must widen
    /// once rather than report nothing.
    func testWidensReadWhenTailMissesTheReading() throws {
        let url = paths.codexSessions.appendingPathComponent("2026/08/27/rollout-big.jsonl")
        let reading = #"{"timestamp":"2026-08-27T10:51:47.735Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":55.0,"window_minutes":300,"resets_at":1787845497}}}}"#
        let filler = String(repeating: #"{"type":"event_msg","payload":{"type":"agent_message"}}"# + "\n", count: 400)
        try Data("\(reading)\n\(filler)".utf8).write(to: url)

        // A tail this small starts after the reading.
        let collector = CodexCollector(paths: paths, tailBytes: 256)
        XCTAssertEqual(collector.collect()?.window(.session)?.window.usedPercent, 55)
    }
}
