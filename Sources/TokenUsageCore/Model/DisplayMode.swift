import Foundation

/// How much of the four available numbers to put in the menu bar. A user
/// preference rather than a fixed choice — the modes share one renderer, so
/// offering all of them costs little more than picking one.
public enum DisplayMode: String, CaseIterable, Sendable, Identifiable {
    case worstOf
    case perTool
    case full

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .worstOf: "Worst of all windows"
        case .perTool: "One per tool"
        case .full: "All four"
        }
    }
}
