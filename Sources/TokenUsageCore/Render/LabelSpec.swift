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
