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
