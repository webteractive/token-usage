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
