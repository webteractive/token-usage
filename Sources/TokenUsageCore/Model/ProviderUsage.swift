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

/// Which limit a window represents.
///
/// Deliberately open-ended: the usage API returns limits as a *list*, and a
/// scoped weekly window (a per-model cap) is invisible to the statusline
/// payload. Modelling this as a fixed pair of fields is what made an earlier
/// version under-report a limit that could block you.
public enum WindowKind: Equatable, Sendable, Hashable {
    case session
    case weeklyAll
    case weeklyScoped(model: String)
    case other(String)

    public var label: String {
        switch self {
        case .session: "5h"
        case .weeklyAll: "7d"
        case .weeklyScoped(let model): "7d \(model)"
        case .other(let name): name
        }
    }

    /// Display rank, so the list reads the same regardless of API ordering.
    var order: Int {
        switch self {
        case .session: 0
        case .weeklyAll: 1
        case .weeklyScoped: 2
        case .other: 3
        }
    }
}

public struct QuotaWindow: Equatable, Sendable {
    public let kind: WindowKind
    public let window: UsageWindow
    /// The API's own flag for the limit currently doing the constraining.
    public let isActive: Bool

    public init(kind: WindowKind, window: UsageWindow, isActive: Bool) {
        self.kind = kind
        self.window = window
        self.isActive = isActive
    }

    public var label: String { kind.label }
}

/// Every quota window one provider reports. Vendor differences are normalised
/// away by the parsers, so nothing downstream knows which tool a number came
/// from — or how many windows that tool happens to expose.
public struct ProviderUsage: Equatable, Sendable {
    public let windows: [QuotaWindow]

    public init(windows: [QuotaWindow]) {
        self.windows = windows.sorted {
            ($0.kind.order, $0.label) < ($1.kind.order, $1.label)
        }
    }

    public static let empty = ProviderUsage(windows: [])

    public func window(_ kind: WindowKind) -> QuotaWindow? {
        windows.first { $0.kind == kind }
    }

    /// The window closest to its limit — the nearest wall, which is the one
    /// worth surfacing in a space that only fits one number.
    public func dominant(now: Date) -> WindowState {
        let states = windows.map { $0.window.state(now: now) }.filter(\.hasData)
        guard let best = states.max(by: { ($0.percent ?? 0) < ($1.percent ?? 0) }) else {
            return .unknown
        }
        return best
    }
}

public extension ProviderUsage {
    /// Readings whose reset times fall this close together describe one window.
    /// The sources disagree by under a second — the API reports 05:59:59.58
    /// where the statusline reports 06:00:00 — and no window is shorter than
    /// hours.
    static let sameWindowTolerance: TimeInterval = 300

    /// Combines several readings of one quota into the best current picture.
    ///
    /// Per limit, the latest window wins, because an earlier one has already
    /// reset. Within a window usage only climbs, so the highest percentage is
    /// the newest reading whatever its timestamp says. That is what makes this
    /// safe to run over session captures: an idle session goes on reporting
    /// the figure it saw last, and taking the latest *writer* is how a login at
    /// 75% came to be shown as 19%.
    static func merged(_ readings: [ProviderUsage]) -> ProviderUsage {
        let byKind = Dictionary(grouping: readings.flatMap(\.windows), by: \.kind)
        return ProviderUsage(windows: byKind.values.compactMap(current))
    }

    private static func current(_ candidates: [QuotaWindow]) -> QuotaWindow? {
        guard let latestReset = candidates.map(\.window.resetsAt).max() else { return nil }
        let window = candidates.filter {
            latestReset.timeIntervalSince($0.window.resetsAt) <= sameWindowTolerance
        }
        guard let top = window.max(by: { $0.window.usedPercent < $1.window.usedPercent }) else {
            return nil
        }

        // A later reading that agrees to within rounding confirms the figure,
        // so the result is as fresh as its most recent confirmation. Without
        // this a statusline's whole 75 would outrank the API's 74.6 and then
        // be dimmed as old.
        let confirmedAt = window
            .filter { top.window.usedPercent - $0.window.usedPercent < 1 }
            .map(\.window.observedAt)
            .max() ?? top.window.observedAt

        return QuotaWindow(
            kind: top.kind,
            window: UsageWindow(
                usedPercent: top.window.usedPercent,
                resetsAt: top.window.resetsAt,
                observedAt: confirmedAt
            ),
            isActive: window.contains(where: \.isActive)
        )
    }
}
