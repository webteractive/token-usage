import Foundation

/// How much of the available numbers to put in the menu bar. A user preference
/// rather than a fixed choice — the modes share one renderer, so offering all of
/// them costs little more than picking one.
public enum DisplayMode: String, CaseIterable, Sendable, Identifiable {
    case worstOf
    case perTool
    case perAccount
    case full

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .worstOf: "Worst of all windows"
        case .perTool: "One per tool"
        case .perAccount: "One per account"
        // "All four" stopped being true when scoped weekly limits appeared, and
        // the README already documents this name.
        case .full: "Every window"
        }
    }
}
