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
    var automaticallyChecksForUpdates: Bool {
        didSet { store(automaticallyChecksForUpdates, "automaticallyChecksForUpdates") }
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
        self.automaticallyChecksForUpdates = defaults.object(
            forKey: "automaticallyChecksForUpdates"
        ) as? Bool ?? true
    }

    private let defaults: UserDefaults

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
