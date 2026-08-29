import XCTest
@testable import TokenUsageCore

final class MenuBarLabelRendererTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(
        _ percent: Double,
        resetsIn: TimeInterval = 3600,
        observedAgo: TimeInterval = 0
    ) -> UsageWindow {
        UsageWindow(
            usedPercent: percent,
            resetsAt: now.addingTimeInterval(resetsIn),
            observedAt: now.addingTimeInterval(-observedAgo)
        )
    }

    /// Builds the common session + weekly pair the old two-field model implied.
    private func pair(session: UsageWindow?, weekly: UsageWindow?) -> ProviderUsage {
        ProviderUsage(windows: [
            session.map { QuotaWindow(kind: .session, window: $0, isActive: false) },
            weekly.map { QuotaWindow(kind: .weeklyAll, window: $0, isActive: false) },
        ].compactMap { $0 })
    }

    private func usage(claude: ProviderUsage, codex: ProviderUsage) -> [Provider: ProviderUsage] {
        [.claude: claude, .codex: codex]
    }

    private var sample: [Provider: ProviderUsage] {
        usage(
            claude: pair(session: window(47), weekly: window(31)),
            codex: pair(session: window(3), weekly: window(1))
        )
    }

    private func render(_ mode: DisplayMode, _ u: [Provider: ProviderUsage]) -> LabelSpec {
        MenuBarLabelRenderer.render(usage: u, mode: mode, thresholds: .default, now: now)
    }

    func testWorstOfShowsHighestAcrossBothProviders() {
        guard case .segments(let segs) = render(.worstOf, sample) else {
            return XCTFail("expected segments")
        }
        XCTAssertEqual(segs.map(\.text), ["● 47%"])
        XCTAssertEqual(segs[0].severity, .normal)
    }

    func testPerToolShowsEachProvidersDominantWindow() {
        guard case .segments(let segs) = render(.perTool, sample) else {
            return XCTFail("expected segments")
        }
        XCTAssertEqual(segs.map(\.text), ["C 47%", "X 3%"])
    }

    func testFullShowsAllFourAsPairs() {
        guard case .segments(let segs) = render(.full, sample) else {
            return XCTFail("expected segments")
        }
        XCTAssertEqual(segs.map(\.text), ["C 47/31", "X 3/1"])
    }

    func testRingsFillProportionallyToDominantWindow() {
        guard case .rings(let rings) = render(.rings, sample) else {
            return XCTFail("expected rings")
        }
        XCTAssertEqual(rings.count, 2)
        XCTAssertEqual(rings[0].fill, 0.47, accuracy: 0.001)
        XCTAssertEqual(rings[1].fill, 0.03, accuracy: 0.001)
    }

    /// Above 100% the arc must clamp rather than wrap around.
    func testRingFillClampsAtFull() {
        let u = usage(
            claude: pair(session: window(150), weekly: nil),
            codex: .empty
        )
        guard case .rings(let rings) = render(.rings, u) else { return XCTFail("expected rings") }
        XCTAssertEqual(rings[0].fill, 1.0, accuracy: 0.001)
    }

    /// Non-normal severity adds its shape marker in the per-tool mode; normal
    /// stays clean so the common case is not noisy.
    func testSeverityMarkersAppearInPerTool() {
        let u = usage(
            claude: pair(session: window(78), weekly: nil),
            codex: pair(session: window(93), weekly: nil)
        )
        guard case .segments(let segs) = render(.perTool, u) else {
            return XCTFail("expected segments")
        }
        XCTAssertEqual(segs.map(\.text), ["C ▲ 78%", "X ■ 93%"])
        XCTAssertEqual(segs[0].severity, .warning)
        XCTAssertEqual(segs[1].severity, .critical)
    }

    /// Worst-of always carries a marker, since the marker is that mode's
    /// identity glyph as well as its severity cue.
    func testWorstOfMarkerTracksSeverity() {
        let u = usage(claude: pair(session: window(93), weekly: nil), codex: .empty)
        guard case .segments(let segs) = render(.worstOf, u) else {
            return XCTFail("expected segments")
        }
        XCTAssertEqual(segs.map(\.text), ["■ 93%"])
    }

    func testStaleReadingIsPrefixedAndFlagged() {
        let u = usage(
            claude: pair(session: window(47, observedAgo: 3600), weekly: nil),
            codex: .empty
        )
        guard case .segments(let segs) = render(.perTool, u) else {
            return XCTFail("expected segments")
        }
        XCTAssertEqual(segs[0].text, "C ‹47%")
        XCTAssertTrue(segs[0].isStale)
    }

    /// "No data" and "no usage" are different claims. A provider that never
    /// reported must never render as 0%.
    func testNoDataRendersEmDashNotZero() {
        let u = usage(claude: .empty, codex: pair(session: window(3), weekly: nil))
        guard case .segments(let segs) = render(.perTool, u) else {
            return XCTFail("expected segments")
        }
        XCTAssertEqual(segs.map(\.text), ["C —", "X 3%"])
        XCTAssertFalse(segs[0].hasData)
    }

    /// A reset window is known to be empty, so 0% here is a real claim.
    func testResetWindowRendersZero() {
        let u = usage(
            claude: pair(session: window(47, resetsIn: -1), weekly: nil),
            codex: .empty
        )
        guard case .segments(let segs) = render(.perTool, u) else {
            return XCTFail("expected segments")
        }
        XCTAssertEqual(segs[0].text, "C 0%")
        XCTAssertTrue(segs[0].hasData)
    }

    func testPercentagesRoundToWholeNumbers() {
        let u = usage(claude: pair(session: window(47.6), weekly: nil), codex: .empty)
        guard case .segments(let segs) = render(.perTool, u) else {
            return XCTFail("expected segments")
        }
        XCTAssertEqual(segs[0].text, "C 48%")
    }

    func testProviderOrderIsAlwaysClaudeThenCodex() {
        guard case .segments(let segs) = render(.perTool, sample) else {
            return XCTFail("expected segments")
        }
        XCTAssertTrue(segs[0].text.hasPrefix("C"))
        XCTAssertTrue(segs[1].text.hasPrefix("X"))
    }
}
