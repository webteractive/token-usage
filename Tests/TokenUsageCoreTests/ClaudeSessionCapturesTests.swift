import XCTest
@testable import TokenUsageCore

final class ClaudeSessionCapturesTests: XCTestCase {

    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_791_650_000)
    private let claude = URL(fileURLWithPath: "/Users/glen/.claude", isDirectory: true)
    private let devops = URL(fileURLWithPath: "/Users/glen/.zetty/accounts/devops", isDirectory: true)

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("captures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(
        _ name: String,
        config: URL,
        sevenDay: Int,
        fiveHour: Int? = nil,
        modifiedAgo: TimeInterval = 0
    ) throws {
        let session = fiveHour.map { #""five_hour":{"used_percentage":\#($0),"resets_at":1791660600},"# } ?? ""
        let json = """
        {"session_id":"\(name)","transcript_path":"\(config.path)/projects/p/\(name).jsonl",
        "rate_limits":{\(session)"seven_day":{"used_percentage":\(sevenDay),"resets_at":1791702000}}}
        """
        let url = directory.appendingPathComponent(name)
        try Data(json.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-modifiedAgo)], ofItemAtPath: url.path
        )
    }

    private func loaded() -> ClaudeSessionCaptures {
        let captures = ClaudeSessionCaptures(directory: directory)
        captures.reload(now: now)
        return captures
    }

    /// Several sessions of one login disagree, and the busiest one is right.
    func testTakesTheHighestReadingAcrossALoginsSessions() throws {
        try write("idle.json", config: claude, sevenDay: 19)
        try write("older.json", config: claude, sevenDay: 54, modifiedAgo: 7200)
        try write("busy.json", config: claude, sevenDay: 75, fiveHour: 21, modifiedAgo: 90)

        let usage = loaded().usage(for: claude)

        XCTAssertEqual(usage.window(.weeklyAll)?.window.usedPercent, 75)
        XCTAssertEqual(usage.window(.session)?.window.usedPercent, 21)
    }

    /// The file's date is the date of the reading, because the shim leaves an
    /// idle session's file alone.
    func testDatesAReadingByItsFile() throws {
        try write("busy.json", config: claude, sevenDay: 75, modifiedAgo: 90)

        let usage = loaded().usage(for: claude)

        XCTAssertEqual(usage.window(.weeklyAll)?.window.observedAt, now.addingTimeInterval(-90))
    }

    /// Every login's sessions share the directory. One login's quota must
    /// never be shown under another's name.
    func testKeepsLoginsApart() throws {
        try write("a.json", config: claude, sevenDay: 75)
        try write("b.json", config: devops, sevenDay: 2)

        let captures = loaded()

        XCTAssertEqual(captures.usage(for: claude).window(.weeklyAll)?.window.usedPercent, 75)
        XCTAssertEqual(captures.usage(for: devops).window(.weeklyAll)?.window.usedPercent, 2)
    }

    func testLoginWithNoSessionsHasNoData() throws {
        try write("a.json", config: claude, sevenDay: 75)

        XCTAssertEqual(loaded().usage(for: devops), .empty)
    }

    func testMissingDirectoryHasNoData() {
        let captures = ClaudeSessionCaptures(directory: directory.appendingPathComponent("absent"))
        captures.reload(now: now)

        XCTAssertEqual(captures.usage(for: claude), .empty)
    }

    /// The shim writes through a temporary named after its process id. Reading
    /// one mid-write would be reading half a payload.
    func testIgnoresTheShimsTemporaries() throws {
        try write("a.json", config: claude, sevenDay: 19)
        try write("b.json.4242", config: claude, sevenDay: 99)

        XCTAssertEqual(loaded().usage(for: claude).window(.weeklyAll)?.window.usedPercent, 19)
    }

    func testUndecodableFileIsSkipped() throws {
        try write("a.json", config: claude, sevenDay: 19)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))

        XCTAssertEqual(loaded().usage(for: claude).window(.weeklyAll)?.window.usedPercent, 19)
    }

    func testDeletesCapturesPastTheirLifetime() throws {
        try write("recent.json", config: claude, sevenDay: 19)
        try write("ancient.json", config: claude, sevenDay: 99, modifiedAgo: ClaudeSessionCaptures.lifetime + 60)

        let usage = loaded().usage(for: claude)

        XCTAssertEqual(usage.window(.weeklyAll)?.window.usedPercent, 19)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("ancient.json").path
        ))
    }

    func testPicksUpAFileThatChanged() throws {
        try write("a.json", config: claude, sevenDay: 19, modifiedAgo: 120)
        let captures = loaded()
        XCTAssertEqual(captures.usage(for: claude).window(.weeklyAll)?.window.usedPercent, 19)

        try write("a.json", config: claude, sevenDay: 20, modifiedAgo: 5)
        captures.reload(now: now)

        XCTAssertEqual(captures.usage(for: claude).window(.weeklyAll)?.window.usedPercent, 20)
    }

    func testForgetsASessionWhoseFileIsGone() throws {
        try write("a.json", config: claude, sevenDay: 19)
        let captures = loaded()

        try FileManager.default.removeItem(at: directory.appendingPathComponent("a.json"))
        captures.reload(now: now)

        XCTAssertEqual(captures.usage(for: claude), .empty)
    }
}
