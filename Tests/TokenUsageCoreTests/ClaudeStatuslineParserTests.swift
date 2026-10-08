import XCTest
@testable import TokenUsageCore

final class ClaudeStatuslineParserTests: XCTestCase {

    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let configDirectory = URL(fileURLWithPath: "/Users/glen/.claude", isDirectory: true)

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
        )
        return try Data(contentsOf: url)
    }

    func testParsesBothWindows() throws {
        let usage = try ClaudeStatuslineParser.parse(fixture("claude-statusline"), observedAt: observedAt, configDirectory: configDirectory)

        XCTAssertEqual(usage.window(.session)?.window.usedPercent, 47)
        XCTAssertEqual(usage.window(.session)?.window.resetsAt, Date(timeIntervalSince1970: 1_787_845_497))
        XCTAssertEqual(usage.window(.session)?.window.observedAt, observedAt)

        XCTAssertEqual(usage.window(.weeklyAll)?.window.usedPercent, 31)
        XCTAssertEqual(usage.window(.weeklyAll)?.window.resetsAt, Date(timeIntervalSince1970: 1_788_333_028))
    }

    /// rate_limits is documented as subscriber-only. Its absence is a normal
    /// state, not a parse error — and must not become a zero.
    func testAbsentRateLimitsYieldsEmptyNotZero() throws {
        let usage = try ClaudeStatuslineParser.parse(fixture("claude-no-rate-limits"), observedAt: observedAt, configDirectory: configDirectory)
        XCTAssertNil(usage.window(.session))
        XCTAssertNil(usage.window(.weeklyAll))
        XCTAssertEqual(usage.dominant(now: observedAt), .unknown)
    }

    func testPartialRateLimitsKeepsPresentWindow() throws {
        let json = #"{"transcript_path":"/Users/glen/.claude/projects/p/s.jsonl","rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1787845497}}}"#
        let usage = try ClaudeStatuslineParser.parse(Data(json.utf8), observedAt: observedAt, configDirectory: configDirectory)
        XCTAssertEqual(usage.window(.session)?.window.usedPercent, 12)
        XCTAssertNil(usage.window(.weeklyAll))
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(
            try ClaudeStatuslineParser.parse(Data("not json".utf8), observedAt: observedAt, configDirectory: configDirectory)
        )
    }

    /// A zetty account whose settings.json was copied from ~/.claude runs the
    /// same shim, so its quota lands in the same file. Reporting it as the
    /// default account's would show one login's usage under another's name.
    func testRejectsPayloadFromAnotherConfigDirectory() {
        let json = #"""
        {"transcript_path":"/Users/glen/.zetty/accounts/devops/projects/p/s.jsonl",
         "rate_limits":{"seven_day":{"used_percentage":26,"resets_at":1791612000}}}
        """#
        XCTAssertThrowsError(
            try ClaudeStatuslineParser.parse(Data(json.utf8), observedAt: observedAt, configDirectory: configDirectory)
        ) { XCTAssertEqual($0 as? ClaudeStatuslineParser.ParseError, .otherAccount) }
    }

    /// A sibling directory sharing the prefix is not inside it.
    func testRejectsSiblingDirectorySharingThePrefix() {
        let json = #"{"transcript_path":"/Users/glen/.claude-work/projects/p/s.jsonl","rate_limits":{}}"#
        XCTAssertThrowsError(
            try ClaudeStatuslineParser.parse(Data(json.utf8), observedAt: observedAt, configDirectory: configDirectory)
        ) { XCTAssertEqual($0 as? ClaudeStatuslineParser.ParseError, .otherAccount) }
    }

    /// A dotfiles-managed ~/.claude is often a symlink, and the transcript path
    /// may name the link's target rather than the link.
    func testAcceptsTranscriptReportedThroughASymlinkedConfigDirectory() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = temp.appendingPathComponent("dotfiles-claude", isDirectory: true)
        let link = temp.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: temp) }

        let transcript = target.appendingPathComponent("projects/p/s.jsonl").path
        let json = #"{"transcript_path":"\#(transcript)","rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1787845497}}}"#
        let usage = try ClaudeStatuslineParser.parse(Data(json.utf8), observedAt: observedAt, configDirectory: link)
        XCTAssertEqual(usage.window(.session)?.window.usedPercent, 12)
    }

    /// Without a transcript path the payload's account cannot be proven, and an
    /// unattributable reading is not shown under any account's name.
    func testRejectsPayloadWithoutTranscriptPath() {
        let json = #"{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1787845497}}}"#
        XCTAssertThrowsError(
            try ClaudeStatuslineParser.parse(Data(json.utf8), observedAt: observedAt, configDirectory: configDirectory)
        ) { XCTAssertEqual($0 as? ClaudeStatuslineParser.ParseError, .otherAccount) }
    }
}
