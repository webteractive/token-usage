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

    /// How this reading renders as a number. The em dash is load-bearing: a
    /// provider that never reported must never read as 0%.
    var numberLabel: String {
        guard let percent else { return "—" }
        return String(Int(percent.rounded()))
    }

    var percentLabel: String {
        hasData ? "\(numberLabel)%" : "—"
    }
}
