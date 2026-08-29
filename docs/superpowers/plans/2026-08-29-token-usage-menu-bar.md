# Token Usage Menu Bar App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu bar app showing 5-hour and 7-day quota usage plus reset countdowns for Claude Code and Codex.

**Architecture:** A pure, fully-testable core SPM library (`TokenUsageCore`) holds the state machine, parsers, renderer, and all file IO; a thin SwiftUI `MenuBarExtra` app target consumes it. Claude data arrives pushed via a dependency-free bash shim chained in front of the user's existing statusline; Codex data is tail-read from the newest rollout file. No network, no credentials, no corpus scanning.

**Tech Stack:** Swift 6.0, SwiftUI `MenuBarExtra`, XCTest, Tuist + local SPM package, FSEvents.

**Spec:** `docs/superpowers/specs/2026-08-29-token-usage-menu-bar-design.md`

## Global Constraints

- **Native only.** SwiftUI + Swift throughout. No web view, no embedded runtime, no scripting bridge. The statusline shim is the sole shell script, and only because Claude Code executes `statusLine.command` as a command.
- `swift-tools-version: 6.0`, `platforms: [.macOS(.v14)]`.
- Test framework is **XCTest** (matches `~/AI/zetty`, the reference project).
- Bundle id `co.webteractive.tokenusage`; `CFBundleName` / display name `Token Usage`.
- Layout follows zetty: `Package.swift` + `Project.swift` + `Tuist.swift` at root, core in `Sources/TokenUsageCore/`, core tests in `Tests/TokenUsageCoreTests/`, app in `App/`.
- **Never display an estimated or derived percentage.** Both providers supply exact figures. A provider with no data shows `—`, never `0%`.
- **The shim must never break the user's statusline.** Passthrough `exec` is the final statement in every path.
- `liveWindow` = **600 seconds** (10 minutes).
- Default thresholds: warning **75**, critical **90**.
- Severity is **never signalled by colour alone** — every severity carries a shape marker (`●` / `▲` / `■`).
- Ships unsandboxed, hardened runtime, notarized, via appdater. Not App Store.
- Commit messages: **no `Co-Authored-By`, no `Claude-Session:` trailer.** Never commit or push without asking Glen.
- Pre-ship pass is `prepare-for-release` (Swift project), not `prepare-for-production`.

---

## File Structure

**Core library — `Sources/TokenUsageCore/`** (everything testable via `swift test`):

| File | Responsibility |
|---|---|
| `Model/UsageWindow.swift` | `UsageWindow`, `WindowState`, `state(now:)` — the live/stale/reset decision |
| `Model/Severity.swift` | `Thresholds`, `Severity`, shape markers |
| `Model/ProviderUsage.swift` | `Provider`, `ProviderUsage`, `dominant(now:)` |
| `Model/DisplayMode.swift` | The four menu bar modes |
| `Parsing/ClaudeStatuslineParser.swift` | Raw statusline JSON → `ProviderUsage` |
| `Parsing/CodexRolloutParser.swift` | Rollout tail chunk → `ProviderUsage` |
| `Render/LabelSpec.swift` | `LabelSpec`, `Segment`, `Ring` — structured render output |
| `Render/MenuBarLabelRenderer.swift` | `(usage, mode, thresholds, now) → LabelSpec`, pure |
| `IO/Paths.swift` | State directory and file locations |
| `IO/StateStore.swift` | Atomic read/write of state files |
| `IO/FileWatcher.swift` | FSEvents wrapper |
| `IO/CodexCollector.swift` | Newest rollout → tail → parse → store |
| `IO/ShimInstaller.swift` | Install/uninstall the statusline shim |
| `Resources/statusline-shim.sh` | The shim template |

**App — `App/`** (SwiftUI only):

| File | Responsibility |
|---|---|
| `TokenUsageApp.swift` | `@main`, `MenuBarExtra` |
| `UsageViewModel.swift` | `@Observable`, combines providers, drives refresh |
| `Preferences.swift` | `@AppStorage`-backed settings |
| `MenuBarLabelView.swift` | Renders a `LabelSpec` |
| `RingView.swift` | Drawn arc for rings mode |
| `DropdownView.swift` | The four rows + countdowns |
| `SettingsView.swift` | Mode, thresholds, launch at login, shim status |

**Tests:** `Tests/TokenUsageCoreTests/` with `Fixtures/` holding real captured payloads.

---

## Task 1: Scaffold package and the window state machine

**Files:**
- Create: `Package.swift`, `Tuist.swift`, `.gitignore`
- Create: `Sources/TokenUsageCore/Model/UsageWindow.swift`
- Test: `Tests/TokenUsageCoreTests/UsageWindowTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `UsageWindow(usedPercent:resetsAt:observedAt:)`, `UsageWindow.state(now:) -> WindowState`, `UsageWindow.liveWindow: TimeInterval`, `WindowState` cases `.live(Double)` / `.stale(Double, since: Date)` / `.reset` / `.unknown`, and `WindowState.percent: Double?` / `.isStale: Bool` / `.hasData: Bool`

- [ ] **Step 1: Create the package manifest**

`Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenUsage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TokenUsageCore", targets: ["TokenUsageCore"]),
    ],
    targets: [
        .target(
            name: "TokenUsageCore",
            resources: [.copy("Resources/statusline-shim.sh")]
        ),
        .testTarget(
            name: "TokenUsageCoreTests",
            dependencies: ["TokenUsageCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

`Tuist.swift`:

```swift
import ProjectDescription

let config = Config()
```

`.gitignore`:

```
.build/
.swiftpm/
build/
Derived/
*.xcodeproj
*.xcworkspace
.DS_Store
dist/
```

Create placeholder resource directories so SPM does not fail on missing paths:

```bash
mkdir -p Sources/TokenUsageCore/{Model,Parsing,Render,IO,Resources}
mkdir -p Tests/TokenUsageCoreTests/Fixtures
printf '#!/usr/bin/env bash\n' > Sources/TokenUsageCore/Resources/statusline-shim.sh
printf '{}\n' > Tests/TokenUsageCoreTests/Fixtures/.keep.json
```

- [ ] **Step 2: Write the failing test**

`Tests/TokenUsageCoreTests/UsageWindowTests.swift`:

```swift
import XCTest
@testable import TokenUsageCore

final class UsageWindowTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(
        percent: Double = 47,
        resetsIn: TimeInterval = 3600,
        observedAgo: TimeInterval = 0
    ) -> UsageWindow {
        UsageWindow(
            usedPercent: percent,
            resetsAt: now.addingTimeInterval(resetsIn),
            observedAt: now.addingTimeInterval(-observedAgo)
        )
    }

    func testFreshObservationIsLive() {
        XCTAssertEqual(window(observedAgo: 0).state(now: now), .live(47))
    }

    /// The live/stale boundary is inclusive: exactly liveWindow old is still live.
    func testObservationAtLiveBoundaryIsStillLive() {
        XCTAssertEqual(window(observedAgo: 600).state(now: now), .live(47))
    }

    func testObservationPastLiveBoundaryIsStale() {
        let since = now.addingTimeInterval(-601)
        XCTAssertEqual(window(observedAgo: 601).state(now: now), .stale(47, since: since))
    }

    /// A window whose resets_at has passed is provably empty, however old the
    /// reading is. This is what makes most staleness self-healing.
    func testPassedResetIsZeroNotStale() {
        XCTAssertEqual(window(resetsIn: -1, observedAgo: 86_400).state(now: now), .reset)
    }

    /// Reset must be checked before staleness, or an old reading of a rolled-over
    /// window reports a stale percentage that is certainly wrong.
    func testResetTakesPrecedenceOverStale() {
        let w = window(percent: 93, resetsIn: -60, observedAgo: 7200)
        XCTAssertEqual(w.state(now: now), .reset)
    }

    func testResetBoundaryIsInclusive() {
        XCTAssertEqual(window(resetsIn: 0).state(now: now), .reset)
    }

    func testPercentAccessor() {
        XCTAssertEqual(WindowState.live(47).percent, 47)
        XCTAssertEqual(WindowState.stale(12, since: now).percent, 12)
        XCTAssertEqual(WindowState.reset.percent, 0)
        XCTAssertNil(WindowState.unknown.percent)
    }

    func testStaleAndDataFlags() {
        XCTAssertTrue(WindowState.stale(1, since: now).isStale)
        XCTAssertFalse(WindowState.live(1).isStale)
        XCTAssertTrue(WindowState.reset.hasData)
        XCTAssertFalse(WindowState.unknown.hasData)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter UsageWindowTests`
Expected: FAIL — `cannot find 'UsageWindow' in scope`

- [ ] **Step 4: Write minimal implementation**

`Sources/TokenUsageCore/Model/UsageWindow.swift`:

```swift
import Foundation

/// One quota window (5-hour or 7-day) as last reported by a provider.
///
/// Both Claude Code and Codex report an exact `used_percentage` and an epoch
/// `resets_at`. Nothing here is estimated.
public struct UsageWindow: Equatable, Sendable {
    public let usedPercent: Double
    public let resetsAt: Date
    /// When this reading was produced — not when it was read off disk.
    public let observedAt: Date

    public init(usedPercent: Double, resetsAt: Date, observedAt: Date) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }
}

/// How much we can currently claim about a window.
public enum WindowState: Equatable, Sendable {
    case live(Double)
    case stale(Double, since: Date)
    /// `resets_at` has passed, so the window is provably empty.
    case reset
    /// Never reported — distinct from zero usage, and displayed differently.
    case unknown
}

public extension UsageWindow {
    /// Gaps shorter than this are normal inside an active session (a long tool
    /// call, extended thinking). Beyond it, the session has almost certainly
    /// ended and the reading should be marked stale.
    static let liveWindow: TimeInterval = 600

    func state(now: Date) -> WindowState {
        // Reset is checked first: a passed resets_at makes the stored percentage
        // certainly wrong, no matter how recently it was observed.
        if now >= resetsAt { return .reset }
        if now.timeIntervalSince(observedAt) <= Self.liveWindow { return .live(usedPercent) }
        return .stale(usedPercent, since: observedAt)
    }
}

public extension WindowState {
    var percent: Double? {
        switch self {
        case .live(let p): p
        case .stale(let p, _): p
        case .reset: 0
        case .unknown: nil
        }
    }

    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }

    var hasData: Bool { percent != nil }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter UsageWindowTests`
Expected: PASS, 8 tests

- [ ] **Step 6: Commit**

```bash
git add Package.swift Tuist.swift .gitignore Sources Tests
git commit -m "feat: add usage window state machine

Live/stale/reset decision as a pure function of an injected clock. Reset is
evaluated first so a passed resets_at wins over a stale reading."
```

---

## Task 2: Severity, thresholds, and provider aggregation

**Files:**
- Create: `Sources/TokenUsageCore/Model/Severity.swift`
- Create: `Sources/TokenUsageCore/Model/ProviderUsage.swift`
- Test: `Tests/TokenUsageCoreTests/SeverityTests.swift`
- Test: `Tests/TokenUsageCoreTests/ProviderUsageTests.swift`

**Interfaces:**
- Consumes: `UsageWindow`, `WindowState` (Task 1)
- Produces: `Thresholds(warning:critical:)` with `.default`; `Severity` cases `.normal`/`.warning`/`.critical` with `Severity.of(_:_:) -> Severity` and `.marker: String`; `Provider` cases `.claude`/`.codex` with `.shortLabel: String` and `.displayName: String`; `ProviderUsage(fiveHour:sevenDay:)` with `.dominant(now:) -> WindowState`

- [ ] **Step 1: Write the failing tests**

`Tests/TokenUsageCoreTests/SeverityTests.swift`:

```swift
import XCTest
@testable import TokenUsageCore

final class SeverityTests: XCTestCase {

    func testDefaultThresholds() {
        XCTAssertEqual(Thresholds.default.warning, 75)
        XCTAssertEqual(Thresholds.default.critical, 90)
    }

    func testSeverityBands() {
        XCTAssertEqual(Severity.of(0), .normal)
        XCTAssertEqual(Severity.of(74.9), .normal)
        XCTAssertEqual(Severity.of(75), .warning)
        XCTAssertEqual(Severity.of(89.9), .warning)
        XCTAssertEqual(Severity.of(90), .critical)
        XCTAssertEqual(Severity.of(150), .critical)
    }

    func testCustomThresholds() {
        let t = Thresholds(warning: 50, critical: 60)
        XCTAssertEqual(Severity.of(55, t), .warning)
        XCTAssertEqual(Severity.of(60, t), .critical)
    }

    /// Colour alone fails for red-green colour deficiency and over arbitrary
    /// wallpapers, so every severity must carry a distinct shape.
    func testMarkersAreDistinct() {
        let markers = [Severity.normal, .warning, .critical].map(\.marker)
        XCTAssertEqual(markers, ["●", "▲", "■"])
        XCTAssertEqual(Set(markers).count, 3)
    }
}
```

`Tests/TokenUsageCoreTests/ProviderUsageTests.swift`:

```swift
import XCTest
@testable import TokenUsageCore

final class ProviderUsageTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ percent: Double, resetsIn: TimeInterval = 3600) -> UsageWindow {
        UsageWindow(
            usedPercent: percent,
            resetsAt: now.addingTimeInterval(resetsIn),
            observedAt: now
        )
    }

    /// The nearest wall is the one worth showing, so the higher window wins —
    /// not the 5-hour one by default.
    func testDominantPicksHigherWindow() {
        let usage = ProviderUsage(fiveHour: window(31), sevenDay: window(47))
        XCTAssertEqual(usage.dominant(now: now), .live(47))
    }

    func testDominantPicksFiveHourWhenHigher() {
        let usage = ProviderUsage(fiveHour: window(80), sevenDay: window(12))
        XCTAssertEqual(usage.dominant(now: now), .live(80))
    }

    /// A reset window counts as 0%, so it must not beat a real reading.
    func testResetWindowLosesToLiveReading() {
        let usage = ProviderUsage(fiveHour: window(0, resetsIn: -1), sevenDay: window(12))
        XCTAssertEqual(usage.dominant(now: now), .live(12))
    }

    func testMissingWindowIsIgnored() {
        let usage = ProviderUsage(fiveHour: nil, sevenDay: window(12))
        XCTAssertEqual(usage.dominant(now: now), .live(12))
    }

    func testNoWindowsIsUnknown() {
        XCTAssertEqual(ProviderUsage(fiveHour: nil, sevenDay: nil).dominant(now: now), .unknown)
    }

    func testProviderLabels() {
        XCTAssertEqual(Provider.claude.shortLabel, "C")
        XCTAssertEqual(Provider.codex.shortLabel, "X")
        XCTAssertEqual(Provider.claude.displayName, "Claude")
        XCTAssertEqual(Provider.codex.displayName, "Codex")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "SeverityTests|ProviderUsageTests"`
Expected: FAIL — `cannot find 'Thresholds' in scope`

- [ ] **Step 3: Write minimal implementation**

`Sources/TokenUsageCore/Model/Severity.swift`:

```swift
import Foundation

public struct Thresholds: Equatable, Sendable {
    public var warning: Double
    public var critical: Double

    public init(warning: Double, critical: Double) {
        self.warning = warning
        self.critical = critical
    }

    public static let `default` = Thresholds(warning: 75, critical: 90)
}

public enum Severity: Equatable, Sendable, Comparable {
    case normal
    case warning
    case critical

    public static func of(_ percent: Double, _ thresholds: Thresholds = .default) -> Severity {
        if percent >= thresholds.critical { return .critical }
        if percent >= thresholds.warning { return .warning }
        return .normal
    }

    /// Shape cue shown alongside colour. Severity is never signalled by colour
    /// alone: amber-vs-red is exactly the pair red-green colour deficiency
    /// collapses, and the menu bar sits over arbitrary wallpaper.
    public var marker: String {
        switch self {
        case .normal: "●"
        case .warning: "▲"
        case .critical: "■"
        }
    }
}
```

`Sources/TokenUsageCore/Model/ProviderUsage.swift`:

```swift
import Foundation

public enum Provider: String, CaseIterable, Sendable {
    case claude
    case codex

    public var shortLabel: String {
        switch self {
        case .claude: "C"
        case .codex: "X"
        }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// Both windows for one provider. Vendor key differences are normalised away by
/// the parsers, so nothing downstream knows which tool a number came from.
public struct ProviderUsage: Equatable, Sendable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?

    public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    public static let empty = ProviderUsage(fiveHour: nil, sevenDay: nil)

    /// The window closest to its limit — the nearest wall, which is the one
    /// worth surfacing in a space that only fits one number.
    public func dominant(now: Date) -> WindowState {
        let states = [fiveHour, sevenDay]
            .compactMap { $0?.state(now: now) }
            .filter(\.hasData)
        guard let best = states.max(by: { ($0.percent ?? 0) < ($1.percent ?? 0) }) else {
            return .unknown
        }
        return best
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "SeverityTests|ProviderUsageTests"`
Expected: PASS, 10 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenUsageCore/Model Tests/TokenUsageCoreTests
git commit -m "feat: add severity bands and provider aggregation

Severity carries a shape marker so it is never signalled by colour alone.
dominant() surfaces the window nearest its limit."
```

---

## Task 3: Claude statusline parser

**Files:**
- Create: `Sources/TokenUsageCore/Parsing/ClaudeStatuslineParser.swift`
- Create: `Tests/TokenUsageCoreTests/Fixtures/claude-statusline.json`
- Create: `Tests/TokenUsageCoreTests/Fixtures/claude-no-rate-limits.json`
- Test: `Tests/TokenUsageCoreTests/ClaudeStatuslineParserTests.swift`

**Interfaces:**
- Consumes: `UsageWindow`, `ProviderUsage` (Tasks 1-2)
- Produces: `ClaudeStatuslineParser.parse(_ data: Data, observedAt: Date) throws -> ProviderUsage`

- [ ] **Step 1: Create the fixtures**

`Tests/TokenUsageCoreTests/Fixtures/claude-statusline.json` — trimmed from the real payload contract:

```json
{
  "model": { "display_name": "Opus 5" },
  "workspace": { "current_dir": "/Users/glen/AI/token-usage" },
  "version": "2.1.251",
  "context_window": {
    "total_input_tokens": 54816,
    "context_window_size": 200000,
    "used_percentage": 27.4
  },
  "rate_limits": {
    "five_hour": { "used_percentage": 47.0, "resets_at": 1787845497 },
    "seven_day": { "used_percentage": 31.0, "resets_at": 1788333028 }
  }
}
```

`Tests/TokenUsageCoreTests/Fixtures/claude-no-rate-limits.json` — an API/Console user, who legitimately has no subscription quota:

```json
{
  "model": { "display_name": "Opus 5" },
  "workspace": { "current_dir": "/Users/glen/AI/token-usage" },
  "version": "2.1.251"
}
```

Delete the placeholder: `rm -f Tests/TokenUsageCoreTests/Fixtures/.keep.json`

- [ ] **Step 2: Write the failing test**

`Tests/TokenUsageCoreTests/ClaudeStatuslineParserTests.swift`:

```swift
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
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter ClaudeStatuslineParserTests`
Expected: FAIL — `cannot find 'ClaudeStatuslineParser' in scope`

- [ ] **Step 4: Write minimal implementation**

`Sources/TokenUsageCore/Parsing/ClaudeStatuslineParser.swift`:

```swift
import Foundation

/// Parses the JSON Claude Code writes to stdin of the configured statusline
/// command. This is the only place Claude's quota exists locally — it is never
/// written to the session JSONL, which is why searching there finds nothing.
public enum ClaudeStatuslineParser {

    private struct Payload: Decodable {
        struct RateLimits: Decodable {
            struct Window: Decodable {
                let used_percentage: Double
                let resets_at: Double
            }
            let five_hour: Window?
            let seven_day: Window?
        }
        let rate_limits: RateLimits?
    }

    /// - Parameter observedAt: when the payload was written (the state file's
    ///   modification date). The statusline payload carries no timestamp of its
    ///   own, so freshness is judged by when it landed on disk.
    public static func parse(_ data: Data, observedAt: Date) throws -> ProviderUsage {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let limits = payload.rate_limits else {
            // Documented as subscriber-only. Absence is normal, not an error,
            // and must surface as "no data" rather than zero usage.
            return .empty
        }
        return ProviderUsage(
            fiveHour: window(limits.five_hour, observedAt: observedAt),
            sevenDay: window(limits.seven_day, observedAt: observedAt)
        )
    }

    private static func window(
        _ raw: Payload.RateLimits.Window?,
        observedAt: Date
    ) -> UsageWindow? {
        guard let raw else { return nil }
        return UsageWindow(
            usedPercent: raw.used_percentage,
            resetsAt: Date(timeIntervalSince1970: raw.resets_at),
            observedAt: observedAt
        )
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter ClaudeStatuslineParserTests`
Expected: PASS, 4 tests

- [ ] **Step 6: Commit**

```bash
git add Sources/TokenUsageCore/Parsing Tests/TokenUsageCoreTests
git commit -m "feat: parse Claude statusline rate_limits

Absent rate_limits means a non-subscriber, which yields no data rather than
zero usage."
```

---

## Task 4: Codex rollout parser

**Files:**
- Create: `Sources/TokenUsageCore/Parsing/CodexRolloutParser.swift`
- Create: `Tests/TokenUsageCoreTests/Fixtures/codex-tail.jsonl`
- Test: `Tests/TokenUsageCoreTests/CodexRolloutParserTests.swift`

**Interfaces:**
- Consumes: `UsageWindow`, `ProviderUsage` (Tasks 1-2)
- Produces: `CodexRolloutParser.parseLatest(chunk: String) -> ProviderUsage?`

**Context the implementer needs.** Codex rollout files are JSONL. The relevant line looks like this (real shape, captured 2026-08-29) — note `rate_limits` sits under `payload`, and the line carries its own ISO8601 `timestamp`, so unlike Claude we get an exact `observedAt` rather than a file mtime:

```json
{"timestamp":"2026-08-27T10:51:47.735Z","ordinal":116,"type":"event_msg",
 "payload":{"type":"token_count","info":{...},
   "rate_limits":{"limit_id":"codex",
     "primary":{"used_percent":3.0,"window_minutes":300,"resets_at":1787845497},
     "secondary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1788333028},
     "plan_type":"plus"}}}
```

`primary` is the 5-hour window, `secondary` the weekly one. Because the collector reads a fixed-size tail, **the first line of a chunk is usually truncated mid-JSON and must be discarded.**

- [ ] **Step 1: Create the fixture**

`Tests/TokenUsageCoreTests/Fixtures/codex-tail.jsonl` — deliberately opens with a truncated line, then a line with no rate limits, then two valid readings so the parser must pick the last:

```
_tokens":1883,"total_tokens":589678}}}}
{"timestamp":"2026-08-27T10:50:00.000Z","ordinal":114,"type":"event_msg","payload":{"type":"agent_message","message":"working"}}
{"timestamp":"2026-08-27T10:51:00.000Z","ordinal":115,"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":2.0,"window_minutes":300,"resets_at":1787845400},"secondary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1788333028},"plan_type":"plus"}}}
{"timestamp":"2026-08-27T10:51:47.735Z","ordinal":116,"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":3.0,"window_minutes":300,"resets_at":1787845497},"secondary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1788333028},"plan_type":"plus"}}}
```

- [ ] **Step 2: Write the failing test**

`Tests/TokenUsageCoreTests/CodexRolloutParserTests.swift`:

```swift
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
        XCTAssertEqual(usage.fiveHour?.usedPercent, 3)
        XCTAssertEqual(usage.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_787_845_497))
        XCTAssertEqual(usage.sevenDay?.usedPercent, 1)
        XCTAssertEqual(usage.sevenDay?.resetsAt, Date(timeIntervalSince1970: 1_788_333_028))
    }

    /// observedAt comes from the line's own timestamp, which is more accurate
    /// than the file's mtime when a session wrote later non-usage events.
    func testObservedAtComesFromLineTimestamp() throws {
        let usage = try XCTUnwrap(CodexRolloutParser.parseLatest(chunk: fixture("codex-tail", "jsonl")))
        let expected = ISO8601DateFormatter.codexParser.date(from: "2026-08-27T10:51:47.735Z")
        XCTAssertEqual(usage.fiveHour?.observedAt, expected)
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
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter CodexRolloutParserTests`
Expected: FAIL — `cannot find 'CodexRolloutParser' in scope`

- [ ] **Step 4: Write minimal implementation**

`Sources/TokenUsageCore/Parsing/CodexRolloutParser.swift`:

```swift
import Foundation

extension ISO8601DateFormatter {
    /// Codex timestamps carry fractional seconds, which the default
    /// configuration rejects.
    static let codexParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Reads the most recent quota reading out of a tail chunk of a Codex rollout
/// file. Codex persists `rate_limits` on `token_count` events, so unlike Claude
/// this data is available directly from disk.
public enum CodexRolloutParser {

    private struct Line: Decodable {
        struct Payload: Decodable {
            struct RateLimits: Decodable {
                struct Window: Decodable {
                    let used_percent: Double
                    let resets_at: Double
                }
                let primary: Window?
                let secondary: Window?
            }
            let rate_limits: RateLimits?
        }
        let timestamp: String?
        let payload: Payload?
    }

    /// - Parameter chunk: the tail of a rollout file. Its first line is usually
    ///   truncated mid-JSON by the fixed-size read and is discarded.
    /// - Returns: the last complete reading, or nil if the chunk holds none.
    public static func parseLatest(chunk: String) -> ProviderUsage? {
        let lines = chunk.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 1 else { return nil }

        // Scan backwards: the newest reading wins, and stopping at the first
        // hit avoids decoding the whole chunk.
        for line in lines.dropFirst().reversed() {
            guard
                let decoded = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)),
                let limits = decoded.payload?.rate_limits,
                limits.primary != nil || limits.secondary != nil
            else { continue }

            let observedAt = decoded.timestamp
                .flatMap(ISO8601DateFormatter.codexParser.date(from:))
                ?? Date()

            return ProviderUsage(
                fiveHour: window(limits.primary, observedAt: observedAt),
                sevenDay: window(limits.secondary, observedAt: observedAt)
            )
        }
        return nil
    }

    private static func window(
        _ raw: Line.Payload.RateLimits.Window?,
        observedAt: Date
    ) -> UsageWindow? {
        guard let raw else { return nil }
        return UsageWindow(
            usedPercent: raw.used_percent,
            resetsAt: Date(timeIntervalSince1970: raw.resets_at),
            observedAt: observedAt
        )
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter CodexRolloutParserTests`
Expected: PASS, 5 tests

- [ ] **Step 6: Commit**

```bash
git add Sources/TokenUsageCore/Parsing Tests/TokenUsageCoreTests
git commit -m "feat: parse Codex rollout rate_limits from a tail chunk

Scans backwards for the newest reading and discards the truncated first line
produced by a fixed-size tail read."
```

---

## Task 5: Display modes and the menu bar label renderer

**Files:**
- Create: `Sources/TokenUsageCore/Model/DisplayMode.swift`
- Create: `Sources/TokenUsageCore/Render/LabelSpec.swift`
- Create: `Sources/TokenUsageCore/Render/MenuBarLabelRenderer.swift`
- Test: `Tests/TokenUsageCoreTests/MenuBarLabelRendererTests.swift`

**Interfaces:**
- Consumes: `Provider`, `ProviderUsage`, `Severity`, `Thresholds`, `WindowState` (Tasks 1-2)
- Produces: `DisplayMode` cases `.worstOf`/`.perTool`/`.rings`/`.full` with `.title: String`; `LabelSpec` cases `.segments([Segment])`/`.rings([Ring])`; `Segment(text:severity:isStale:hasData:)`; `Ring(fill:severity:isStale:hasData:)`; `MenuBarLabelRenderer.render(usage:mode:thresholds:now:) -> LabelSpec` taking `usage: [Provider: ProviderUsage]`

- [ ] **Step 1: Write the failing test**

`Tests/TokenUsageCoreTests/MenuBarLabelRendererTests.swift`:

```swift
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

    private func usage(claude: ProviderUsage, codex: ProviderUsage) -> [Provider: ProviderUsage] {
        [.claude: claude, .codex: codex]
    }

    private var sample: [Provider: ProviderUsage] {
        usage(
            claude: ProviderUsage(fiveHour: window(47), sevenDay: window(31)),
            codex: ProviderUsage(fiveHour: window(3), sevenDay: window(1))
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
            claude: ProviderUsage(fiveHour: window(150), sevenDay: nil),
            codex: .empty
        )
        guard case .rings(let rings) = render(.rings, u) else { return XCTFail("expected rings") }
        XCTAssertEqual(rings[0].fill, 1.0, accuracy: 0.001)
    }

    /// Non-normal severity adds its shape marker in the per-tool mode; normal
    /// stays clean so the common case is not noisy.
    func testSeverityMarkersAppearInPerTool() {
        let u = usage(
            claude: ProviderUsage(fiveHour: window(78), sevenDay: nil),
            codex: ProviderUsage(fiveHour: window(93), sevenDay: nil)
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
        let u = usage(claude: ProviderUsage(fiveHour: window(93), sevenDay: nil), codex: .empty)
        guard case .segments(let segs) = render(.worstOf, u) else {
            return XCTFail("expected segments")
        }
        XCTAssertEqual(segs.map(\.text), ["■ 93%"])
    }

    func testStaleReadingIsPrefixedAndFlagged() {
        let u = usage(
            claude: ProviderUsage(fiveHour: window(47, observedAgo: 3600), sevenDay: nil),
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
        let u = usage(claude: .empty, codex: ProviderUsage(fiveHour: window(3), sevenDay: nil))
        guard case .segments(let segs) = render(.perTool, u) else {
            return XCTFail("expected segments")
        }
        XCTAssertEqual(segs.map(\.text), ["C —", "X 3%"])
        XCTAssertFalse(segs[0].hasData)
    }

    /// A reset window is known to be empty, so 0% here is a real claim.
    func testResetWindowRendersZero() {
        let u = usage(
            claude: ProviderUsage(fiveHour: window(47, resetsIn: -1), sevenDay: nil),
            codex: .empty
        )
        guard case .segments(let segs) = render(.perTool, u) else {
            return XCTFail("expected segments")
        }
        XCTAssertEqual(segs[0].text, "C 0%")
        XCTAssertTrue(segs[0].hasData)
    }

    func testPercentagesRoundToWholeNumbers() {
        let u = usage(claude: ProviderUsage(fiveHour: window(47.6), sevenDay: nil), codex: .empty)
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MenuBarLabelRendererTests`
Expected: FAIL — `cannot find 'DisplayMode' in scope`

- [ ] **Step 3: Write minimal implementation**

`Sources/TokenUsageCore/Model/DisplayMode.swift`:

```swift
import Foundation

/// How much of the four available numbers to put in the menu bar. A user
/// preference rather than a fixed choice — the modes share one renderer, so
/// offering all of them costs little more than picking one.
public enum DisplayMode: String, CaseIterable, Sendable, Identifiable {
    case worstOf
    case perTool
    case rings
    case full

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .worstOf: "Worst of all windows"
        case .perTool: "One per tool"
        case .rings: "Rings"
        case .full: "All four"
        }
    }
}
```

`Sources/TokenUsageCore/Render/LabelSpec.swift`:

```swift
import Foundation

/// A structured description of the menu bar content. Keeping this separate from
/// SwiftUI is what makes every display mode assertable in a unit test.
public enum LabelSpec: Equatable, Sendable {
    case segments([Segment])
    case rings([Ring])
}

public struct Segment: Equatable, Sendable {
    public let text: String
    public let severity: Severity
    public let isStale: Bool
    /// False when the provider has never reported. Rendered as "—", never 0%.
    public let hasData: Bool

    public init(text: String, severity: Severity, isStale: Bool, hasData: Bool) {
        self.text = text
        self.severity = severity
        self.isStale = isStale
        self.hasData = hasData
    }
}

public struct Ring: Equatable, Sendable {
    /// Clamped to 0...1.
    public let fill: Double
    public let severity: Severity
    public let isStale: Bool
    public let hasData: Bool

    public init(fill: Double, severity: Severity, isStale: Bool, hasData: Bool) {
        self.fill = fill
        self.severity = severity
        self.isStale = isStale
        self.hasData = hasData
    }
}
```

`Sources/TokenUsageCore/Render/MenuBarLabelRenderer.swift`:

```swift
import Foundation

public enum MenuBarLabelRenderer {

    /// Providers always render in a fixed order so the bar does not reshuffle
    /// as numbers change.
    private static let order: [Provider] = [.claude, .codex]

    public static func render(
        usage: [Provider: ProviderUsage],
        mode: DisplayMode,
        thresholds: Thresholds = .default,
        now: Date
    ) -> LabelSpec {
        switch mode {
        case .worstOf: renderWorstOf(usage, thresholds, now)
        case .perTool: renderPerTool(usage, thresholds, now)
        case .full: renderFull(usage, thresholds, now)
        case .rings: renderRings(usage, thresholds, now)
        }
    }

    // MARK: - Modes

    private static func renderWorstOf(
        _ usage: [Provider: ProviderUsage],
        _ thresholds: Thresholds,
        _ now: Date
    ) -> LabelSpec {
        let states = order.compactMap { usage[$0]?.dominant(now: now) }.filter(\.hasData)
        guard let worst = states.max(by: { ($0.percent ?? 0) < ($1.percent ?? 0) }) else {
            return .segments([Segment(text: "—", severity: .normal, isStale: false, hasData: false)])
        }
        let severity = Severity.of(worst.percent ?? 0, thresholds)
        // The marker doubles as this mode's identity glyph, so it is always
        // shown and simply changes shape with severity.
        let text = "\(severity.marker) \(stalePrefix(worst))\(percentText(worst))"
        return .segments([
            Segment(text: text, severity: severity, isStale: worst.isStale, hasData: true)
        ])
    }

    private static func renderPerTool(
        _ usage: [Provider: ProviderUsage],
        _ thresholds: Thresholds,
        _ now: Date
    ) -> LabelSpec {
        .segments(order.map { provider in
            let state = usage[provider]?.dominant(now: now) ?? .unknown
            let severity = Severity.of(state.percent ?? 0, thresholds)
            let body = state.hasData
                ? "\(marker(severity))\(stalePrefix(state))\(percentText(state))"
                : "—"
            return Segment(
                text: "\(provider.shortLabel) \(body)",
                severity: state.hasData ? severity : .normal,
                isStale: state.isStale,
                hasData: state.hasData
            )
        })
    }

    private static func renderFull(
        _ usage: [Provider: ProviderUsage],
        _ thresholds: Thresholds,
        _ now: Date
    ) -> LabelSpec {
        .segments(order.map { provider in
            let provided = usage[provider] ?? .empty
            let five = provided.fiveHour?.state(now: now) ?? .unknown
            let seven = provided.sevenDay?.state(now: now) ?? .unknown
            let dominant = provided.dominant(now: now)
            let severity = Severity.of(dominant.percent ?? 0, thresholds)

            let body: String
            if dominant.hasData {
                body = "\(marker(severity))\(stalePrefix(dominant))"
                    + "\(number(five))/\(number(seven))"
            } else {
                body = "—"
            }
            return Segment(
                text: "\(provider.shortLabel) \(body)",
                severity: dominant.hasData ? severity : .normal,
                isStale: dominant.isStale,
                hasData: dominant.hasData
            )
        })
    }

    private static func renderRings(
        _ usage: [Provider: ProviderUsage],
        _ thresholds: Thresholds,
        _ now: Date
    ) -> LabelSpec {
        .rings(order.map { provider in
            let state = usage[provider]?.dominant(now: now) ?? .unknown
            let percent = state.percent ?? 0
            return Ring(
                fill: min(max(percent / 100, 0), 1),
                severity: Severity.of(percent, thresholds),
                isStale: state.isStale,
                hasData: state.hasData
            )
        })
    }

    // MARK: - Formatting

    /// Shown only when it carries information; a marker on every normal reading
    /// would just be noise.
    private static func marker(_ severity: Severity) -> String {
        severity == .normal ? "" : "\(severity.marker) "
    }

    private static func stalePrefix(_ state: WindowState) -> String {
        state.isStale ? "‹" : ""
    }

    private static func percentText(_ state: WindowState) -> String {
        "\(number(state))%"
    }

    private static func number(_ state: WindowState) -> String {
        guard let percent = state.percent else { return "—" }
        return String(Int(percent.rounded()))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MenuBarLabelRendererTests`
Expected: PASS, 12 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenUsageCore Tests/TokenUsageCoreTests
git commit -m "feat: render menu bar label for all four display modes

Structured LabelSpec output keeps every mode assertable without SwiftUI. No
data renders as an em dash, never as zero."
```

---

## Task 6: Paths and atomic state store

**Files:**
- Create: `Sources/TokenUsageCore/IO/Paths.swift`
- Create: `Sources/TokenUsageCore/IO/StateStore.swift`
- Test: `Tests/TokenUsageCoreTests/StateStoreTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: `Paths(home:)` with `.stateDirectory`, `.claudeRawState`, `.codexState`, `.claudeSettings`, `.claudeSettingsBackup`, `.shimScript`, `.codexSessions`, and `Paths.live`; `StateStore(paths:)` with `write(_ data: Data, to url: URL) throws`, `read(_ url: URL) throws -> (data: Data, modifiedAt: Date)`, `exists(_ url: URL) -> Bool`

- [ ] **Step 1: Write the failing test**

`Tests/TokenUsageCoreTests/StateStoreTests.swift`:

```swift
import XCTest
@testable import TokenUsageCore

final class StateStoreTests: XCTestCase {

    private var home: URL!
    private var store: StateStore!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tokenusage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        store = StateStore(paths: Paths(home: home))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testWriteThenReadRoundTrips() throws {
        let url = store.paths.codexState
        try store.write(Data(#"{"a":1}"#.utf8), to: url)
        let result = try store.read(url)
        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), #"{"a":1}"#)
    }

    func testWriteCreatesStateDirectory() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths.stateDirectory.path))
        try store.write(Data("x".utf8), to: store.paths.codexState)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths.stateDirectory.path))
    }

    func testReadReportsModificationDate() throws {
        let url = store.paths.codexState
        try store.write(Data("x".utf8), to: url)
        let result = try store.read(url)
        XCTAssertEqual(result.modifiedAt.timeIntervalSinceNow, 0, accuracy: 5)
    }

    /// The raw Claude payload carries session metadata, so it must not be
    /// world-readable.
    func testWrittenFileIsOwnerOnly() throws {
        let url = store.paths.claudeRawState
        try store.write(Data("x".utf8), to: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attrs[.posixPermissions] as? NSNumber, 0o600)
    }

    func testOverwriteReplacesContent() throws {
        let url = store.paths.codexState
        try store.write(Data("first".utf8), to: url)
        try store.write(Data("second".utf8), to: url)
        XCTAssertEqual(String(decoding: try store.read(url).data, as: UTF8.self), "second")
    }

    func testReadMissingFileThrows() {
        XCTAssertThrowsError(try store.read(store.paths.codexState))
    }

    func testExists() throws {
        XCTAssertFalse(store.exists(store.paths.codexState))
        try store.write(Data("x".utf8), to: store.paths.codexState)
        XCTAssertTrue(store.exists(store.paths.codexState))
    }

    func testPathsAreRootedAtGivenHome() {
        let paths = Paths(home: URL(fileURLWithPath: "/tmp/fakehome"))
        XCTAssertEqual(
            paths.claudeSettings.path,
            "/tmp/fakehome/.claude/settings.json"
        )
        XCTAssertEqual(paths.shimScript.path, "/tmp/fakehome/.claude/tokenusage-shim.sh")
        XCTAssertEqual(paths.codexSessions.path, "/tmp/fakehome/.codex/sessions")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StateStoreTests`
Expected: FAIL — `cannot find 'Paths' in scope`

- [ ] **Step 3: Write minimal implementation**

`Sources/TokenUsageCore/IO/Paths.swift`:

```swift
import Foundation

/// Every filesystem location the app touches, rooted at an injectable home so
/// the installer and store can be tested against a temporary directory.
public struct Paths: Sendable {
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    public static let live = Paths(home: FileManager.default.homeDirectoryForCurrentUser)

    public var stateDirectory: URL {
        home
            .appendingPathComponent("Library/Application Support/TokenUsage", isDirectory: true)
    }

    /// The verbatim statusline payload, written by the shim.
    public var claudeRawState: URL { stateDirectory.appendingPathComponent("claude-raw.json") }
    public var codexState: URL { stateDirectory.appendingPathComponent("codex.json") }

    public var claudeDirectory: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    public var claudeSettings: URL { claudeDirectory.appendingPathComponent("settings.json") }
    public var claudeSettingsBackup: URL {
        claudeDirectory.appendingPathComponent("settings.json.tokenusage-backup")
    }
    public var shimScript: URL { claudeDirectory.appendingPathComponent("tokenusage-shim.sh") }

    public var codexSessions: URL {
        home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }
}
```

`Sources/TokenUsageCore/IO/StateStore.swift`:

```swift
import Foundation

/// Reads and writes the small state files the collectors produce.
///
/// Writes go through a temporary sibling and an atomic rename, so a reader can
/// never observe a half-written file.
public struct StateStore: Sendable {
    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    public func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Sibling temp file keeps the rename within one filesystem, which is
        // what makes it atomic.
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try data.write(to: temp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    public func read(_ url: URL) throws -> (data: Data, modifiedAt: Date) {
        let data = try Data(contentsOf: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (data, attrs[.modificationDate] as? Date ?? Date())
    }

    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StateStoreTests`
Expected: PASS, 8 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenUsageCore/IO Tests/TokenUsageCoreTests
git commit -m "feat: add path resolution and atomic state store

Writes via a sibling temp file and rename so readers never see a partial
file. Paths take an injectable home for testing."
```

---

## Task 7: Statusline shim installer

**Files:**
- Create: `Sources/TokenUsageCore/Resources/statusline-shim.sh` (replace the Task 1 placeholder)
- Create: `Sources/TokenUsageCore/IO/ShimInstaller.swift`
- Test: `Tests/TokenUsageCoreTests/ShimInstallerTests.swift`

**Interfaces:**
- Consumes: `Paths` (Task 6)
- Produces: `ShimInstaller(paths:)` with `status() -> ShimStatus`, `install() throws`, `uninstall() throws`; `ShimStatus` cases `.notInstalled(existingCommand: String?)`, `.installed(delegate: String?)`, `.modifiedExternally(current: String)`

**Context the implementer needs.** This is the only part of the system that edits user configuration, and the only part that can break the user's terminal. Two rules dominate every decision here:

1. The shim's passthrough `exec` is the last statement on every path, so a failed state write never costs the user their statusline.
2. `statusLine.command` must point at a standalone script in `~/.claude/`, **never** at a binary inside the app bundle — a bundle path would be orphaned if the app were moved or deleted, breaking the status bar with no obvious cause.

- [ ] **Step 1: Write the shim template**

`Sources/TokenUsageCore/Resources/statusline-shim.sh`. `__STATE_FILE__` and `__DELEGATE__` are replaced with literals at install time, so the shim reads no configuration of its own:

```bash
#!/usr/bin/env bash
# Token Usage statusline shim — installed by the Token Usage menu bar app.
#
# Claude Code passes session JSON on stdin, including rate_limits (the 5-hour
# and 7-day quota), which it does not write anywhere else. This captures that
# payload and then hands stdin to the user's real statusline unchanged.
#
# Every failure path still delegates: losing a usage update is acceptable,
# losing the user's statusline is not.
#
# Uninstall by restoring statusLine.command in ~/.claude/settings.json.

input="$(cat)"

state="__STATE_FILE__"
tmp="${state}.$$"
mkdir -p "$(dirname "$state")" 2>/dev/null
printf '%s' "$input" > "$tmp" 2>/dev/null && chmod 600 "$tmp" 2>/dev/null \
  && mv -f "$tmp" "$state" 2>/dev/null
rm -f "$tmp" 2>/dev/null

delegate="__DELEGATE__"
if [ -n "$delegate" ]; then
  printf '%s' "$input" | exec /bin/sh -c "$delegate"
fi
exit 0
```

- [ ] **Step 2: Write the failing test**

`Tests/TokenUsageCoreTests/ShimInstallerTests.swift`:

```swift
import XCTest
@testable import TokenUsageCore

final class ShimInstallerTests: XCTestCase {

    private var home: URL!
    private var paths: Paths!
    private var installer: ShimInstaller!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tokenusage-shim-\(UUID().uuidString)")
        paths = Paths(home: home)
        installer = ShimInstaller(paths: paths)
        try FileManager.default.createDirectory(at: paths.claudeDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func writeSettings(_ json: String) throws {
        try Data(json.utf8).write(to: paths.claudeSettings)
    }

    private func settingsCommand() throws -> String? {
        let data = try Data(contentsOf: paths.claudeSettings)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let statusLine = object?["statusLine"] as? [String: Any]
        return statusLine?["command"] as? String
    }

    // MARK: - Status detection

    func testStatusWithNoSettingsIsNotInstalled() {
        XCTAssertEqual(installer.status(), .notInstalled(existingCommand: nil))
    }

    func testStatusDetectsExistingCommand() throws {
        try writeSettings(#"{"statusLine":{"command":"~/.claude/statusline.sh","type":"command"}}"#)
        XCTAssertEqual(installer.status(), .notInstalled(existingCommand: "~/.claude/statusline.sh"))
    }

    func testStatusAfterInstallReportsDelegate() throws {
        try writeSettings(#"{"statusLine":{"command":"~/.claude/statusline.sh","type":"command"}}"#)
        try installer.install()
        XCTAssertEqual(installer.status(), .installed(delegate: "~/.claude/statusline.sh"))
    }

    /// If the user rewires statusLine.command by hand we must notice and ask,
    /// not silently wrap or clobber their change.
    func testStatusDetectsExternalModification() throws {
        try writeSettings(#"{"statusLine":{"command":"~/.claude/statusline.sh","type":"command"}}"#)
        try installer.install()
        try writeSettings(#"{"statusLine":{"command":"/usr/local/bin/other","type":"command"}}"#)
        XCTAssertEqual(installer.status(), .modifiedExternally(current: "/usr/local/bin/other"))
    }

    // MARK: - Install

    func testInstallPointsSettingsAtShim() throws {
        try writeSettings(#"{"statusLine":{"command":"~/.claude/statusline.sh","type":"command"}}"#)
        try installer.install()
        XCTAssertEqual(try settingsCommand(), paths.shimScript.path)
    }

    func testInstallWritesExecutableShim() throws {
        try writeSettings("{}")
        try installer.install()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: paths.shimScript.path))
    }

    func testInstalledShimHasNoUnreplacedPlaceholders() throws {
        try writeSettings(#"{"statusLine":{"command":"~/.claude/statusline.sh","type":"command"}}"#)
        try installer.install()
        let script = try String(contentsOf: paths.shimScript, encoding: .utf8)
        XCTAssertFalse(script.contains("__STATE_FILE__"))
        XCTAssertFalse(script.contains("__DELEGATE__"))
        XCTAssertTrue(script.contains(paths.claudeRawState.path))
        XCTAssertTrue(script.contains("~/.claude/statusline.sh"))
    }

    func testInstallBacksUpSettings() throws {
        let original = #"{"statusLine":{"command":"~/.claude/statusline.sh","type":"command"}}"#
        try writeSettings(original)
        try installer.install()
        let backup = try String(contentsOf: paths.claudeSettingsBackup, encoding: .utf8)
        XCTAssertEqual(backup, original)
    }

    func testInstallPreservesOtherSettingsKeys() throws {
        try writeSettings(#"{"hooks":{"Stop":[]},"statusLine":{"command":"a","type":"command"}}"#)
        try installer.install()
        let data = try Data(contentsOf: paths.claudeSettings)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["hooks"])
    }

    func testInstallWithNoExistingStatuslineLeavesDelegateEmpty() throws {
        try writeSettings("{}")
        try installer.install()
        let script = try String(contentsOf: paths.shimScript, encoding: .utf8)
        XCTAssertTrue(script.contains(#"delegate=""#))
        XCTAssertEqual(installer.status(), .installed(delegate: nil))
    }

    /// Installing twice must not wrap the shim around itself.
    func testInstallIsIdempotent() throws {
        try writeSettings(#"{"statusLine":{"command":"~/.claude/statusline.sh","type":"command"}}"#)
        try installer.install()
        try installer.install()
        XCTAssertEqual(installer.status(), .installed(delegate: "~/.claude/statusline.sh"))
        XCTAssertEqual(try settingsCommand(), paths.shimScript.path)
    }

    // MARK: - Uninstall

    func testUninstallRestoresOriginalCommand() throws {
        try writeSettings(#"{"statusLine":{"command":"~/.claude/statusline.sh","type":"command"}}"#)
        try installer.install()
        try installer.uninstall()
        XCTAssertEqual(try settingsCommand(), "~/.claude/statusline.sh")
        XCTAssertEqual(installer.status(), .notInstalled(existingCommand: "~/.claude/statusline.sh"))
    }

    func testUninstallRemovesShimScript() throws {
        try writeSettings("{}")
        try installer.install()
        try installer.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.shimScript.path))
    }

    func testUninstallWithNoOriginalRemovesStatusLineKey() throws {
        try writeSettings("{}")
        try installer.install()
        try installer.uninstall()
        XCTAssertNil(try settingsCommand())
    }

    // MARK: - Behaviour of the installed shim

    /// The contract that matters most: the user's statusline output must survive
    /// the shim byte for byte.
    func testShimPassesStdinThroughUnchanged() throws {
        let delegate = paths.claudeDirectory.appendingPathComponent("fake-statusline.sh")
        try Data("#!/bin/sh\ncat | sed 's/^/OUT:/'\n".utf8).write(to: delegate)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: delegate.path)
        try writeSettings(#"{"statusLine":{"command":"\#(delegate.path)","type":"command"}}"#)
        try installer.install()

        let payload = #"{"rate_limits":{"five_hour":{"used_percentage":47,"resets_at":1787845497}}}"#
        let output = try run(paths.shimScript.path, stdin: payload)

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "OUT:\(payload)")
    }

    func testShimCapturesPayloadToStateFile() throws {
        try writeSettings("{}")
        try installer.install()

        let payload = #"{"rate_limits":{"five_hour":{"used_percentage":47,"resets_at":1787845497}}}"#
        _ = try run(paths.shimScript.path, stdin: payload)

        let captured = try String(contentsOf: paths.claudeRawState, encoding: .utf8)
        XCTAssertEqual(captured, payload)
    }

    /// If the state write fails, the user's statusline must still run.
    func testShimDelegatesEvenWhenStateWriteFails() throws {
        let delegate = paths.claudeDirectory.appendingPathComponent("fake-statusline.sh")
        try Data("#!/bin/sh\ncat >/dev/null; echo DELEGATED\n".utf8).write(to: delegate)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: delegate.path)
        try writeSettings(#"{"statusLine":{"command":"\#(delegate.path)","type":"command"}}"#)
        try installer.install()

        // Make the state directory unwritable.
        try FileManager.default.createDirectory(at: paths.stateDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: paths.stateDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: paths.stateDirectory.path
            )
        }

        let output = try run(paths.shimScript.path, stdin: "{}")
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "DELEGATED")
    }

    // MARK: - Helper

    private func run(_ path: String, stdin: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [path]

        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()

        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(decoding: data, as: UTF8.self)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter ShimInstallerTests`
Expected: FAIL — `cannot find 'ShimInstaller' in scope`

- [ ] **Step 4: Write minimal implementation**

`Sources/TokenUsageCore/IO/ShimInstaller.swift`:

```swift
import Foundation

public enum ShimStatus: Equatable, Sendable {
    /// The shim is not wired up. Carries whatever statusline the user already has.
    case notInstalled(existingCommand: String?)
    /// The shim is wired up and delegates to `delegate` (nil when the user had none).
    case installed(delegate: String?)
    /// The shim script exists but settings point elsewhere — the user rewired it
    /// by hand. Do not clobber; ask.
    case modifiedExternally(current: String)
}

public enum ShimInstallError: Error, Equatable {
    case templateMissing
    case settingsNotJSONObject
}

/// Installs and removes the statusline shim.
///
/// The only component that edits user configuration, and the only one that can
/// break the user's terminal, so it backs up `settings.json` before every write
/// and restores it verbatim on uninstall.
public struct ShimInstaller: Sendable {
    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    // MARK: - Status

    public func status() -> ShimStatus {
        let current = currentCommand()
        let shimPath = paths.shimScript.path

        guard FileManager.default.fileExists(atPath: shimPath) else {
            return .notInstalled(existingCommand: current)
        }
        guard current == shimPath else {
            if let current { return .modifiedExternally(current: current) }
            return .notInstalled(existingCommand: nil)
        }
        return .installed(delegate: installedDelegate())
    }

    // MARK: - Install

    public func install() throws {
        let delegate: String?
        switch status() {
        case .installed(let existing):
            // Re-installing must not wrap the shim around itself, so the
            // recorded delegate is carried over rather than re-read.
            delegate = existing
        case .notInstalled(let existing):
            delegate = selfReferenceGuard(existing)
        case .modifiedExternally(let current):
            delegate = selfReferenceGuard(current)
        }

        try backupSettings()
        try writeShim(delegate: delegate)
        try setCommand(paths.shimScript.path)
    }

    // MARK: - Uninstall

    public func uninstall() throws {
        let delegate = installedDelegate()
        try setCommand(delegate)
        try? FileManager.default.removeItem(at: paths.shimScript)
    }

    /// A delegate pointing at the shim itself would make it invoke itself
    /// forever, which would hang the statusline rather than merely break it.
    private func selfReferenceGuard(_ command: String?) -> String? {
        command == paths.shimScript.path ? nil : command
    }

    // MARK: - Shim script

    private func writeShim(delegate: String?) throws {
        guard
            let url = Bundle.module.url(forResource: "statusline-shim", withExtension: "sh"),
            let template = try? String(contentsOf: url, encoding: .utf8)
        else { throw ShimInstallError.templateMissing }

        let script = template
            .replacingOccurrences(of: "__STATE_FILE__", with: paths.claudeRawState.path)
            .replacingOccurrences(of: "__DELEGATE__", with: delegate ?? "")

        try FileManager.default.createDirectory(
            at: paths.claudeDirectory, withIntermediateDirectories: true
        )
        try Data(script.utf8).write(to: paths.shimScript)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: paths.shimScript.path
        )
    }

    /// Recovers the delegate by reading it back out of the installed script,
    /// so the app holds no separate state that could drift from reality.
    private func installedDelegate() -> String? {
        guard
            let script = try? String(contentsOf: paths.shimScript, encoding: .utf8),
            let line = script.split(separator: "\n").first(where: { $0.hasPrefix("delegate=") })
        else { return nil }

        let value = line.dropFirst("delegate=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return value.isEmpty ? nil : value
    }

    // MARK: - settings.json

    private func settingsObject() -> [String: Any] {
        guard
            let data = try? Data(contentsOf: paths.claudeSettings),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private func currentCommand() -> String? {
        (settingsObject()["statusLine"] as? [String: Any])?["command"] as? String
    }

    private func backupSettings() throws {
        guard FileManager.default.fileExists(atPath: paths.claudeSettings.path) else { return }
        // Only the pre-install state is worth keeping; never overwrite an
        // existing backup with an already-shimmed settings file.
        guard !FileManager.default.fileExists(atPath: paths.claudeSettingsBackup.path) else { return }
        try FileManager.default.copyItem(at: paths.claudeSettings, to: paths.claudeSettingsBackup)
    }

    private func setCommand(_ command: String?) throws {
        var object = settingsObject()
        if let command {
            object["statusLine"] = ["command": command, "type": "command"]
        } else {
            object.removeValue(forKey: "statusLine")
        }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: paths.claudeDirectory, withIntermediateDirectories: true
        )
        try data.write(to: paths.claudeSettings)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter ShimInstallerTests`
Expected: PASS, 16 tests

- [ ] **Step 6: Commit**

```bash
git add Sources/TokenUsageCore Tests/TokenUsageCoreTests
git commit -m "feat: install and remove the Claude statusline shim

Chains in front of any existing statusline and delegates on every path, so a
failed capture never costs the user their status bar. Idempotent, backs up
settings.json, and detects external rewiring instead of clobbering it."
```

---

## Task 8: Codex collector

**Files:**
- Create: `Sources/TokenUsageCore/IO/CodexCollector.swift`
- Test: `Tests/TokenUsageCoreTests/CodexCollectorTests.swift`

**Interfaces:**
- Consumes: `Paths` (Task 6), `CodexRolloutParser` (Task 4), `ProviderUsage` (Task 2)
- Produces: `CodexCollector(paths:tailBytes:)` with `newestRollout() -> URL?`, `collect() -> ProviderUsage?`; default `tailBytes` = 262_144

**Context the implementer needs.** Rollout files live at `~/.codex/sessions/YYYY/MM/DD/rollout-<ISO>-<uuid>.jsonl` and can reach hundreds of megabytes — the largest on the target machine is 328 MB. Reading one whole is not acceptable; a 256 KB tail read measured 18 ms. Quota is account-wide, so the newest file by modification date holds the current truth. When the tail holds no reading, widen **once** to 4 MB before giving up.

- [ ] **Step 1: Write the failing test**

`Tests/TokenUsageCoreTests/CodexCollectorTests.swift`:

```swift
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
        XCTAssertEqual(collector.collect()?.fiveHour?.usedPercent, 42)
    }

    func testCollectReadsBothWindows() throws {
        try writeRollout("rollout-a.jsonl", percent: 3, modified: Date())
        let usage = try XCTUnwrap(CodexCollector(paths: paths).collect())
        XCTAssertEqual(usage.fiveHour?.usedPercent, 3)
        XCTAssertEqual(usage.sevenDay?.usedPercent, 1)
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

        XCTAssertEqual(CodexCollector(paths: paths).collect()?.fiveHour?.usedPercent, 7)
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
        XCTAssertEqual(collector.collect()?.fiveHour?.usedPercent, 55)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CodexCollectorTests`
Expected: FAIL — `cannot find 'CodexCollector' in scope`

- [ ] **Step 3: Write minimal implementation**

`Sources/TokenUsageCore/IO/CodexCollector.swift`:

```swift
import Foundation

/// Reads the current Codex quota from the newest rollout file.
///
/// Rollout files reach hundreds of megabytes, so only a tail is read — a 256 KB
/// tail measures ~18 ms against a corpus containing a 328 MB file. Quota is
/// account-wide, so the most recently modified file holds the current truth.
public struct CodexCollector: Sendable {
    public let paths: Paths
    public let tailBytes: Int

    /// Used when the first tail lands past the last reading. Bounded so a
    /// pathological file cannot pull the whole corpus into memory.
    private static let widenedTailBytes = 4 * 1024 * 1024

    public init(paths: Paths, tailBytes: Int = 256 * 1024) {
        self.paths = paths
        self.tailBytes = tailBytes
    }

    public func newestRollout() -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: paths.codexSessions,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: (url: URL, modified: Date)?
        for case let url as URL in walker {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else { continue }

            if newest == nil || modified > newest!.modified {
                newest = (url, modified)
            }
        }
        return newest?.url
    }

    public func collect() -> ProviderUsage? {
        guard let url = newestRollout() else { return nil }
        if let usage = read(url, bytes: tailBytes) { return usage }
        // Widen once: the first tail can begin after the last reading in a
        // session that kept writing non-usage events.
        guard tailBytes < Self.widenedTailBytes else { return nil }
        return read(url, bytes: Self.widenedTailBytes)
    }

    private func read(_ url: URL, bytes: Int) -> ProviderUsage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }

        // A tail that starts at byte 0 has no truncated first line, but the
        // parser always drops one — so give it a sacrificial blank line.
        let text = String(decoding: data, as: UTF8.self)
        return CodexRolloutParser.parseLatest(chunk: offset == 0 ? "\n" + text : text)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CodexCollectorTests`
Expected: PASS, 6 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenUsageCore/IO Tests/TokenUsageCoreTests
git commit -m "feat: collect Codex quota from newest rollout tail

Reads a 256KB tail of the most recently modified rollout and widens once when
the reading falls outside it, so a 328MB session file stays cheap."
```

---

## Task 9: File watcher

**Files:**
- Create: `Sources/TokenUsageCore/IO/FileWatcher.swift`
- Test: `Tests/TokenUsageCoreTests/FileWatcherTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: `FileWatcher(urls:debounce:onChange:)` with `start()`, `stop()`; default `debounce` = 0.2 seconds

- [ ] **Step 1: Write the failing test**

`Tests/TokenUsageCoreTests/FileWatcherTests.swift`:

```swift
import XCTest
@testable import TokenUsageCore

final class FileWatcherTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tokenusage-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testFiresWhenAWatchedDirectoryChanges() throws {
        let fired = expectation(description: "change reported")
        let watcher = FileWatcher(urls: [directory]) { fired.fulfill() }
        watcher.start()
        defer { watcher.stop() }

        try Data("x".utf8).write(to: directory.appendingPathComponent("a.json"))

        wait(for: [fired], timeout: 5)
    }

    /// Writers touch a file several times in quick succession; the app should
    /// reparse once, not once per event.
    func testRapidChangesAreCoalesced() throws {
        let fired = expectation(description: "change reported")
        fired.assertForOverFulfill = false

        let count = NSMutableArray()
        let watcher = FileWatcher(urls: [directory], debounce: 0.4) {
            count.add(1)
            fired.fulfill()
        }
        watcher.start()
        defer { watcher.stop() }

        for i in 0..<10 {
            try Data("x".utf8).write(to: directory.appendingPathComponent("f\(i).json"))
        }

        wait(for: [fired], timeout: 5)
        // Let the debounce window close before counting.
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertLessThan(count.count, 10)
    }

    func testStopEndsNotifications() throws {
        let watcher = FileWatcher(urls: [directory]) {
            XCTFail("callback fired after stop")
        }
        watcher.start()
        watcher.stop()

        try Data("x".utf8).write(to: directory.appendingPathComponent("a.json"))
        Thread.sleep(forTimeInterval: 1.0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FileWatcherTests`
Expected: FAIL — `cannot find 'FileWatcher' in scope`

- [ ] **Step 3: Write minimal implementation**

`Sources/TokenUsageCore/IO/FileWatcher.swift`:

```swift
import CoreServices
import Foundation

/// Watches directories with FSEvents and reports changes on the main queue.
///
/// Writers touch a file several times in quick succession (temp file, chmod,
/// rename), so events are debounced into a single callback.
public final class FileWatcher: @unchecked Sendable {

    private let urls: [URL]
    private let debounce: TimeInterval
    private let onChange: () -> Void

    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "co.webteractive.tokenusage.watcher")

    public init(urls: [URL], debounce: TimeInterval = 0.2, onChange: @escaping () -> Void) {
        self.urls = urls
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        guard stream == nil, !urls.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().schedule()
        }

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            urls.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            )
        ) else { return }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FileWatcherTests`
Expected: PASS, 3 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenUsageCore/IO Tests/TokenUsageCoreTests
git commit -m "feat: add debounced FSEvents file watcher

Coalesces the burst of events a temp-file-and-rename write produces into one
callback."
```

---

## Task 10: App target and first runnable menu bar

**Files:**
- Create: `Project.swift`
- Create: `App/TokenUsageApp.swift`
- Create: `App/UsageViewModel.swift`
- Create: `App/Preferences.swift`
- Create: `App/MenuBarLabelView.swift`

**Interfaces:**
- Consumes: everything from Tasks 1-9
- Produces: `UsageViewModel(paths:preferences:)` with `.labelSpec: LabelSpec`, `.usage: [Provider: ProviderUsage]`, `.start()`, `.refresh()`; `Preferences` with `.displayMode: DisplayMode`, `.warningThreshold: Double`, `.criticalThreshold: Double`, `.thresholds: Thresholds`

This task ends with an app that launches and shows real numbers. No dropdown or settings UI yet.

- [ ] **Step 1: Write the Tuist manifest**

`Project.swift`:

```swift
import ProjectDescription

let project = Project(
    name: "TokenUsage",
    packages: [.local(path: ".")],
    targets: [
        .target(
            name: "TokenUsage",
            destinations: .macOS,
            product: .app,
            bundleId: "co.webteractive.tokenusage",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                // Menu bar only: no Dock icon, no main window.
                "LSUIElement": true,
                "CFBundleName": "Token Usage",
                "CFBundleDisplayName": "Token Usage",
                "CFBundleShortVersionString": "0.1.0",
                "LSApplicationCategoryType": "public.app-category.developer-tools",
            ]),
            sources: ["App/**"],
            dependencies: [.package(product: "TokenUsageCore")]
        ),
    ]
)
```

- [ ] **Step 2: Write preferences**

`App/Preferences.swift`:

```swift
import SwiftUI
import TokenUsageCore

/// User settings. Display format is a preference rather than a fixed choice —
/// the modes share one renderer, so offering all of them costs almost nothing.
@Observable
final class Preferences {
    var displayMode: DisplayMode {
        didSet { store(displayMode.rawValue, "displayMode") }
    }
    var warningThreshold: Double {
        didSet { store(warningThreshold, "warningThreshold") }
    }
    var criticalThreshold: Double {
        didSet { store(criticalThreshold, "criticalThreshold") }
    }

    var thresholds: Thresholds {
        Thresholds(warning: warningThreshold, critical: criticalThreshold)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: "displayMode") ?? DisplayMode.perTool.rawValue
        self.displayMode = DisplayMode(rawValue: raw) ?? .perTool
        let warning = defaults.object(forKey: "warningThreshold") as? Double
        let critical = defaults.object(forKey: "criticalThreshold") as? Double
        self.warningThreshold = warning ?? Thresholds.default.warning
        self.criticalThreshold = critical ?? Thresholds.default.critical
    }

    private let defaults: UserDefaults

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
```

- [ ] **Step 3: Write the view model**

`App/UsageViewModel.swift`:

```swift
import Foundation
import Observation
import TokenUsageCore

@Observable
@MainActor
final class UsageViewModel {

    private(set) var usage: [Provider: ProviderUsage] = [:]
    private(set) var shimStatus: ShimStatus = .notInstalled(existingCommand: nil)

    let paths: Paths
    private let store: StateStore
    private let codex: CodexCollector
    private let installer: ShimInstaller
    private let preferences: Preferences

    private var watcher: FileWatcher?
    private var ticker: Timer?

    init(paths: Paths = .live, preferences: Preferences) {
        self.paths = paths
        self.preferences = preferences
        self.store = StateStore(paths: paths)
        self.codex = CodexCollector(paths: paths)
        self.installer = ShimInstaller(paths: paths)
    }

    var labelSpec: LabelSpec {
        MenuBarLabelRenderer.render(
            usage: usage,
            mode: preferences.displayMode,
            thresholds: preferences.thresholds,
            now: .now
        )
    }

    func start() {
        refresh()

        watcher = FileWatcher(urls: [paths.stateDirectory, paths.codexSessions]) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        watcher?.start()

        // A window can roll over with nobody writing anything, so re-evaluate on
        // a slow tick as well. State is derived from an injected clock, so this
        // only needs to fire often enough for a countdown to look alive.
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        ticker?.invalidate()
        ticker = nil
    }

    func refresh() {
        usage[.claude] = readClaude() ?? .empty
        usage[.codex] = codex.collect() ?? .empty
        shimStatus = installer.status()
    }

    func installShim() throws { try installer.install(); refresh() }
    func uninstallShim() throws { try installer.uninstall(); refresh() }

    private func readClaude() -> ProviderUsage? {
        guard let result = try? store.read(paths.claudeRawState) else { return nil }
        // The statusline payload carries no timestamp, so the file's own
        // modification date is when the reading was produced.
        return try? ClaudeStatuslineParser.parse(result.data, observedAt: result.modifiedAt)
    }
}
```

- [ ] **Step 4: Write the label view and app entry point**

`App/MenuBarLabelView.swift`:

```swift
import SwiftUI
import TokenUsageCore

extension Severity {
    var color: Color {
        switch self {
        case .normal: .primary
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// Renders a LabelSpec. Colour is only ever a secondary cue — the shape marker
/// baked into the segment text carries the same information.
struct MenuBarLabelView: View {
    let spec: LabelSpec

    var body: some View {
        switch spec {
        case .segments(let segments):
            HStack(spacing: 4) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(segment.text)
                        .foregroundStyle(segment.severity.color)
                        .opacity(segment.isStale ? 0.55 : 1)
                }
            }
        case .rings(let rings):
            HStack(spacing: 4) {
                ForEach(Array(rings.enumerated()), id: \.offset) { _, ring in
                    RingView(ring: ring)
                }
            }
        }
    }
}
```

`App/TokenUsageApp.swift`:

```swift
import SwiftUI
import TokenUsageCore

@main
struct TokenUsageApp: App {
    @State private var preferences: Preferences
    @State private var model: UsageViewModel

    init() {
        // One Preferences instance shared by the view model and the settings
        // UI, so a mode change re-renders the menu bar immediately.
        let preferences = Preferences()
        _preferences = State(initialValue: preferences)
        _model = State(initialValue: UsageViewModel(preferences: preferences))
    }

    var body: some Scene {
        MenuBarExtra {
            DropdownView(model: model, preferences: preferences)
        } label: {
            MenuBarLabelView(spec: model.labelSpec)
                .task { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 5: Add a temporary dropdown so the app compiles**

`App/DropdownView.swift` — replaced properly in Task 11:

```swift
import SwiftUI
import TokenUsageCore

struct DropdownView: View {
    let model: UsageViewModel
    let preferences: Preferences

    var body: some View {
        VStack(alignment: .leading) {
            Text("Token Usage")
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding()
    }
}
```

Add a placeholder `App/RingView.swift` so `MenuBarLabelView` compiles; Task 11 replaces it:

```swift
import SwiftUI
import TokenUsageCore

struct RingView: View {
    let ring: Ring
    var body: some View { Circle().frame(width: 12, height: 12) }
}
```

- [ ] **Step 6: Generate, build, and run**

```bash
tuist generate --no-open
xcodebuild -workspace TokenUsage.xcworkspace -scheme TokenUsage -configuration Debug build
```

Expected: build succeeds. Launch the built app; a menu bar item appears. It shows `C — · X 3%` before the shim is installed — Claude has no data yet, and shows an em dash rather than a fabricated zero.

- [ ] **Step 7: Commit**

```bash
git add Project.swift App
git commit -m "feat: add menu bar app target and view model

MenuBarExtra reading both state files with an FSEvents watcher and a slow
tick so countdowns advance while nothing is being written."
```

---

## Task 11: Dropdown and rings

**Files:**
- Modify: `App/DropdownView.swift` (replace the Task 10 placeholder)
- Modify: `App/RingView.swift` (replace the Task 10 placeholder)
- Create: `Sources/TokenUsageCore/Render/CountdownFormatter.swift`
- Test: `Tests/TokenUsageCoreTests/CountdownFormatterTests.swift`

**Interfaces:**
- Consumes: `UsageWindow`, `WindowState`, `Provider`, `Ring` (Tasks 1-5), `UsageViewModel` (Task 10)
- Produces: `CountdownFormatter.reset(for: UsageWindow?, now: Date) -> String`, `CountdownFormatter.observed(_ state: WindowState) -> String?`

- [ ] **Step 1: Write the failing test**

`Tests/TokenUsageCoreTests/CountdownFormatterTests.swift`:

```swift
import XCTest
@testable import TokenUsageCore

final class CountdownFormatterTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(resetsIn: TimeInterval, observedAgo: TimeInterval = 0) -> UsageWindow {
        UsageWindow(
            usedPercent: 10,
            resetsAt: now.addingTimeInterval(resetsIn),
            observedAt: now.addingTimeInterval(-observedAgo)
        )
    }

    func testFormatsHoursAndMinutes() {
        XCTAssertEqual(CountdownFormatter.reset(for: window(resetsIn: 8040), now: now), "resets in 2h 14m")
    }

    func testFormatsMinutesOnly() {
        XCTAssertEqual(CountdownFormatter.reset(for: window(resetsIn: 600), now: now), "resets in 10m")
    }

    func testFormatsDaysAndHours() {
        XCTAssertEqual(CountdownFormatter.reset(for: window(resetsIn: 356_400), now: now), "resets in 4d 3h")
    }

    /// A passed reset is the good case — say so plainly rather than showing a
    /// negative countdown.
    func testPassedResetReadsAsElapsed() {
        XCTAssertEqual(CountdownFormatter.reset(for: window(resetsIn: -10_800), now: now), "window reset 3h ago")
    }

    func testMissingWindowHasNoCountdown() {
        XCTAssertEqual(CountdownFormatter.reset(for: nil, now: now), "no data")
    }

    func testObservedTextOnlyForStaleReadings() {
        XCTAssertNil(CountdownFormatter.observed(.live(47)))
        XCTAssertNil(CountdownFormatter.observed(.reset))
        let since = Date(timeIntervalSince1970: 1_787_845_000)
        XCTAssertNotNil(CountdownFormatter.observed(.stale(47, since: since)))
        XCTAssertTrue(CountdownFormatter.observed(.stale(47, since: since))!.hasPrefix("as of "))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CountdownFormatterTests`
Expected: FAIL — `cannot find 'CountdownFormatter' in scope`

- [ ] **Step 3: Write minimal implementation**

`Sources/TokenUsageCore/Render/CountdownFormatter.swift`:

```swift
import Foundation

public enum CountdownFormatter {

    /// Countdowns render in local time; resets_at is epoch UTC, so this keeps
    /// them right across timezone changes and DST.
    public static func reset(for window: UsageWindow?, now: Date) -> String {
        guard let window else { return "no data" }
        let interval = window.resetsAt.timeIntervalSince(now)
        if interval <= 0 {
            return "window reset \(duration(-interval)) ago"
        }
        return "resets in \(duration(interval))"
    }

    /// Only stale readings need an "as of" — a live one is current by
    /// definition, and a reset one is certain regardless of its age.
    public static func observed(_ state: WindowState) -> String? {
        guard case .stale(_, let since) = state else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return "as of \(formatter.string(from: since))"
    }

    private static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CountdownFormatterTests`
Expected: PASS, 6 tests

- [ ] **Step 5: Write the real dropdown and ring views**

`App/RingView.swift`:

```swift
import SwiftUI
import TokenUsageCore

/// A drawn arc sized for the menu bar. Severity changes both the colour and the
/// cap style, so the ring is still readable without colour.
struct RingView: View {
    let ring: Ring

    var body: some View {
        ZStack {
            Circle()
                .stroke(.tertiary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: ring.hasData ? ring.fill : 0)
                .stroke(
                    ring.severity.color,
                    style: StrokeStyle(lineWidth: 2, lineCap: ring.severity == .normal ? .round : .butt)
                )
                .rotationEffect(.degrees(-90))
            if !ring.hasData {
                Text("—").font(.system(size: 7))
            }
        }
        .frame(width: 13, height: 13)
        .opacity(ring.isStale ? 0.55 : 1)
    }
}
```

`App/DropdownView.swift`:

```swift
import SwiftUI
import TokenUsageCore

struct DropdownView: View {
    let model: UsageViewModel
    let preferences: Preferences

    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Provider.allCases, id: \.self) { provider in
                providerSection(provider)
            }

            if case .notInstalled = model.shimStatus {
                Divider()
                shimPrompt
            }

            Divider()

            HStack {
                Button("Settings…") { showingSettings = true }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 260)
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model, preferences: preferences)
        }
    }

    @ViewBuilder
    private func providerSection(_ provider: Provider) -> some View {
        let usage = model.usage[provider] ?? .empty
        VStack(alignment: .leading, spacing: 3) {
            Text(provider.displayName).font(.headline)
            row("5h", usage.fiveHour)
            row("7d", usage.sevenDay)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ window: UsageWindow?) -> some View {
        let now = Date.now
        let state = window?.state(now: now) ?? .unknown
        let severity = Severity.of(state.percent ?? 0, preferences.thresholds)

        HStack(spacing: 6) {
            Text(label)
                .frame(width: 22, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(percentText(state))
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(state.hasData ? severity.color : .secondary)
                .opacity(state.isStale ? 0.6 : 1)
            Text(CountdownFormatter.observed(state) ?? CountdownFormatter.reset(for: window, now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .monospacedDigit()
    }

    private func percentText(_ state: WindowState) -> String {
        guard let percent = state.percent else { return "—" }
        return "\(Int(percent.rounded()))%"
    }

    private var shimPrompt: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude reporting is off").font(.caption).bold()
            Text("Claude Code only reports quota to its statusline. Installing the helper captures it; your existing statusline keeps working.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Install helper") { try? model.installShim() }
        }
    }
}
```

- [ ] **Step 6: Build and verify**

```bash
tuist generate --no-open
xcodebuild -workspace TokenUsage.xcworkspace -scheme TokenUsage -configuration Debug build
```

Expected: build succeeds. Open the menu bar item — four rows appear with countdowns, and Codex's 5-hour row reads `0%` with `window reset … ago` when its `resets_at` has passed.

- [ ] **Step 7: Commit**

```bash
git add Sources/TokenUsageCore/Render App
git commit -m "feat: add dropdown rows, countdowns, and rings

Stale rows show 'as of' instead of a countdown; a rolled-over window reads as
reset rather than showing a negative timer."
```

---

## Task 12: Settings and launch at login

**Files:**
- Create: `App/SettingsView.swift`
- Modify: `App/TokenUsageApp.swift` (add the login-item toggle wiring)
- Modify: `Project.swift` (no new entitlements; confirm `LSUIElement`)

**Interfaces:**
- Consumes: `Preferences` (Task 10), `UsageViewModel` (Task 10), `DisplayMode`, `Thresholds`, `ShimStatus`
- Produces: `SettingsView(model:preferences:)`

- [ ] **Step 1: Write the settings view**

`App/SettingsView.swift`:

```swift
import ServiceManagement
import SwiftUI
import TokenUsageCore

struct SettingsView: View {
    let model: UsageViewModel
    let preferences: Preferences

    @Environment(\.dismiss) private var dismiss
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var shimError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Token Usage").font(.title3).bold()

            display
            Divider()
            thresholds
            Divider()
            claudeReporting
            Divider()

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var display: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Menu bar shows", selection: Binding(
                get: { preferences.displayMode },
                set: { preferences.displayMode = $0 }
            )) {
                ForEach(DisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            // Live preview, so the choice is made by seeing rather than reading.
            MenuBarLabelView(spec: model.labelSpec)
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var thresholds: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Thresholds").font(.headline)
            slider("Warning", value: Binding(
                get: { preferences.warningThreshold },
                set: { preferences.warningThreshold = $0 }
            ))
            slider("Critical", value: Binding(
                get: { preferences.criticalThreshold },
                set: { preferences.criticalThreshold = $0 }
            ))
            Text("Severity is shown by shape as well as colour, so it stays readable without relying on hue.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func slider(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(value: value, in: 10...100, step: 5)
            Text("\(Int(value.wrappedValue))%").monospacedDigit().frame(width: 44)
        }
    }

    private var claudeReporting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude reporting").font(.headline)

            switch model.shimStatus {
            case .installed(let delegate):
                Label("Helper installed", systemImage: "checkmark.circle")
                if let delegate {
                    Text("Your statusline still runs: \(delegate)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("Remove helper") { perform(model.uninstallShim) }

            case .notInstalled(let existing):
                Text("Claude Code reports quota only to its statusline command. The helper captures it and passes your statusline through unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                if let existing {
                    Text("Will chain in front of: \(existing)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("Install helper") { perform(model.installShim) }

            case .modifiedExternally(let current):
                Label("Statusline changed outside this app", systemImage: "exclamationmark.triangle")
                Text("statusLine.command now points at \(current). Reinstalling will chain in front of it.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Reinstall helper") { perform(model.installShim) }
            }

            if let shimError {
                Text(shimError).font(.caption2).foregroundStyle(.red)
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            shimError = nil
        } catch {
            shimError = error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Build and verify manually**

```bash
tuist generate --no-open
xcodebuild -workspace TokenUsage.xcworkspace -scheme TokenUsage -configuration Debug build
```

Then check by hand:
1. Open Settings; switch display mode and confirm the live preview and the menu bar both change.
2. Click **Install helper**. Confirm `~/.claude/settings.json` now has `statusLine.command` pointing at `~/.claude/tokenusage-shim.sh`, and that `~/.claude/settings.json.tokenusage-backup` exists.
3. **Confirm your terminal statusline is unchanged** in a running Claude Code session — this is the contract that matters most.
4. Send a message in Claude Code, then confirm the Claude rows populate.
5. Click **Remove helper**; confirm `settings.json` points back at `~/.claude/statusline.sh`.

- [ ] **Step 3: Run the whole suite**

Run: `swift test`
Expected: PASS, all tests

- [ ] **Step 4: Commit**

```bash
git add App
git commit -m "feat: add settings, thresholds, and launch at login

Display mode carries a live preview, and the Claude helper reports whether it
is installed, chained, or externally rewired."
```

---

## Task 13: Release readiness

**Files:**
- Create: `README.md`
- Modify: whatever `prepare-for-release` surfaces

- [ ] **Step 1: Write the README**

`README.md` covering: what the app shows; that both providers' figures are exact and nothing is estimated; why the Claude helper exists and that it chains in front of an existing statusline; how to uninstall; the four display modes; and that it ships unsandboxed via appdater.

- [ ] **Step 2: Run the release readiness pass**

Invoke the `prepare-for-release` skill (Swift project — **not** `prepare-for-production`). Address what it reports.

- [ ] **Step 3: Confirm the full suite passes**

Run: `swift test`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: add README"
```

- [ ] **Step 5: Ask Glen before releasing**

Do not tag, push, or publish to appdater without asking.

---

## Self-Review Notes

Checked against the spec:

- **Statusline discovery / exact figures** → Tasks 3, 7. No estimation path exists anywhere in the code.
- **No corpus parsing** → Task 8 tail-reads only; nothing reads `~/.claude/projects`.
- **Shim never breaks the statusline** → Task 7, asserted by `testShimPassesStdinThroughUnchanged` and `testShimDelegatesEvenWhenStateWriteFails`.
- **Shim is a standalone script, not a bundle binary** → Task 7 rationale and `Paths.shimScript`.
- **Four installer states** → Task 7, one test each.
- **`liveWindow` 600s, thresholds 75/90** → Tasks 1, 2.
- **Reset beats stale** → Task 1, `testResetTakesPrecedenceOverStale`.
- **Four display modes as a preference** → Tasks 5, 10, 12.
- **Shape markers, never colour alone** → Tasks 2, 5, 11.
- **No data renders `—`, never 0%** → Tasks 3, 5, 11.
- **Local-time countdowns from epoch `resets_at`** → Task 11.
- **Non-subscriber has no quota** → Task 3, `testAbsentRateLimitsYieldsEmptyNotZero`.
- **Debounced FSEvents** → Task 9.
- **Unsandboxed, `LSUIElement`, appdater** → Tasks 10, 13.
- **Native throughout** → no web view, embedded runtime, or scripting bridge in any task; the shim is the sole shell script and is required by Claude Code's command interface.

Type consistency: `ProviderUsage.empty`, `WindowState.hasData`, `Severity.marker`, `Severity.color`, `Paths.claudeRawState`, `CountdownFormatter.reset(for:now:)`, and `CountdownFormatter.observed(_:)` are each defined once and used with the same signature throughout.
