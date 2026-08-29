import XCTest
@testable import TokenUsageCore

/// Talks to the real `codex app-server` on this machine. Opt-in, because it
/// depends on Codex being installed and logged in: run with
/// `TOKENUSAGE_LIVE=1 swift test --filter CodexAppServerLiveTests`.
final class CodexAppServerLiveTests: XCTestCase {

    func testFetchesLiveQuota() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TOKENUSAGE_LIVE"] == "1",
            "set TOKENUSAGE_LIVE=1 to run"
        )
        try XCTSkipIf(CodexAppServerClient.locateBinary() == nil, "codex not installed")

        let usage = try CodexAppServerClient().fetch()
        XCTAssertFalse(usage.windows.isEmpty, "expected at least one window")

        for quota in usage.windows {
            let state = quota.window.state(now: .now)
            print("  \(quota.label)  \(state.percentLabel)  \(CountdownFormatter.reset(for: quota.window, now: .now))")
            XCTAssertGreaterThanOrEqual(quota.window.usedPercent, 0)
            XCTAssertLessThanOrEqual(quota.window.usedPercent, 200)
        }
        XCTAssertNotNil(usage.window(.session), "the codex bucket should yield a session window")
    }
}
