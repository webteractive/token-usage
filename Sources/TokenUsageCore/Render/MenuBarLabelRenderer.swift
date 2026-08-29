import Foundation

public enum MenuBarLabelRenderer {

    /// Providers always render in a fixed order so the bar does not reshuffle
    /// as numbers change.
    private static let order: [Provider] = [.claude, .codex]

    public static func render(
        usage: [Provider: ProviderUsage],
        mode: DisplayMode,
        thresholds: Thresholds = .default,
        now: Date
    ) -> LabelSpec {
        switch mode {
        case .worstOf: renderWorstOf(usage, thresholds, now)
        case .perTool: renderPerTool(usage, thresholds, now)
        case .full: renderFull(usage, thresholds, now)
        }
    }

    // MARK: - Modes

    private static func renderWorstOf(
        _ usage: [Provider: ProviderUsage],
        _ thresholds: Thresholds,
        _ now: Date
    ) -> LabelSpec {
        let states = order.compactMap { usage[$0]?.dominant(now: now) }.filter(\.hasData)
        guard let worst = states.max(by: { ($0.percent ?? 0) < ($1.percent ?? 0) }) else {
            return [Segment(text: "—", severity: .normal, isStale: false, hasData: false)]
        }
        let severity = Severity.of(worst.percent ?? 0, thresholds)
        // The marker doubles as this mode's identity glyph, so it is always
        // shown and simply changes shape with severity.
        let text = "\(severity.marker) \(stalePrefix(worst))\(worst.percentLabel)"
        return [Segment(text: text, severity: severity, isStale: worst.isStale, hasData: true)]
    }

    private static func renderPerTool(
        _ usage: [Provider: ProviderUsage],
        _ thresholds: Thresholds,
        _ now: Date
    ) -> LabelSpec {
        order.map { provider in
            let state = usage[provider]?.dominant(now: now) ?? .unknown
            let severity = Severity.of(state.percent ?? 0, thresholds)
            let body = state.hasData
                ? "\(marker(severity))\(stalePrefix(state))\(state.percentLabel)"
                : "—"
            return Segment(
                text: "\(provider.shortLabel) \(body)",
                severity: state.hasData ? severity : .normal,
                isStale: state.isStale,
                hasData: state.hasData
            )
        }
    }

    private static func renderFull(
        _ usage: [Provider: ProviderUsage],
        _ thresholds: Thresholds,
        _ now: Date
    ) -> LabelSpec {
        order.map { provider in
            let provided = usage[provider] ?? .empty
            let parts = provided.windows
                .map { $0.window.state(now: now).numberLabel }
                .joined(separator: "/")
            let dominant = provided.dominant(now: now)
            let severity = Severity.of(dominant.percent ?? 0, thresholds)

            let body: String
            if dominant.hasData {
                body = "\(marker(severity))\(stalePrefix(dominant))\(parts)"
            } else {
                body = "—"
            }
            return Segment(
                text: "\(provider.shortLabel) \(body)",
                severity: dominant.hasData ? severity : .normal,
                isStale: dominant.isStale,
                hasData: dominant.hasData
            )
        }
    }

    // MARK: - Formatting

    /// Shown only when it carries information; a marker on every normal reading
    /// would just be noise.
    private static func marker(_ severity: Severity) -> String {
        severity == .normal ? "" : "\(severity.marker) "
    }

    private static func stalePrefix(_ state: WindowState) -> String {
        state.isStale ? "‹" : ""
    }

}
