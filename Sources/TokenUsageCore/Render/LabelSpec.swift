import Foundation

/// The menu bar content, as data. Keeping this separate from SwiftUI is what
/// makes every display mode assertable in a unit test.
public typealias LabelSpec = [Segment]

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
