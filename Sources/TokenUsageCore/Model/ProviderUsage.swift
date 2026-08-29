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
