import Foundation

public enum MenuBarLabelRenderer {

    /// Sources arrive in a fixed order resolved at discovery, so the bar does
    /// not reshuffle as numbers change.
    public static func render(
        usage: [SourceID: ProviderUsage],
        sources: [SourceDescriptor],
        mode: DisplayMode,
        thresholds: Thresholds = .default,
        now: Date
    ) -> LabelSpec {
        switch mode {
        case .worstOf: renderWorstOf(usage, sources, thresholds, now)
        case .perTool: renderPerTool(usage, sources, thresholds, now)
        case .perAccount: renderPerSource(usage, sources, thresholds, now, windows: false)
        case .full: renderPerSource(usage, sources, thresholds, now, windows: true)
        }
    }

    // MARK: - Modes

    private static func renderWorstOf(
        _ usage: [SourceID: ProviderUsage],
        _ sources: [SourceDescriptor],
        _ thresholds: Thresholds,
        _ now: Date
    ) -> LabelSpec {
        let states = sources.compactMap { usage[$0.id]?.dominant(now: now) }.filter(\.hasData)
        guard let worst = states.max(by: { ($0.percent ?? 0) < ($1.percent ?? 0) }) else {
            return [Segment(text: "—", severity: .normal, isStale: false, hasData: false)]
        }
        let severity = Severity.of(worst.percent ?? 0, thresholds)
        // The marker doubles as this mode's identity glyph, so it is always
        // shown and simply changes shape with severity.
        let text = "\(severity.marker) \(stalePrefix(worst))\(worst.percentLabel)"
        return [Segment(text: text, severity: severity, isStale: worst.isStale, hasData: true)]
    }

    /// One segment per vendor: several Claude logins collapse to whichever is
    /// closest to a wall. This is what keeps the bar a fixed width as accounts
    /// are added, which is why it stays the default.
    private static func renderPerTool(
        _ usage: [SourceID: ProviderUsage],
        _ sources: [SourceDescriptor],
        _ thresholds: Thresholds,
        _ now: Date
    ) -> LabelSpec {
        var seen: [Provider] = []
        for source in sources where !seen.contains(source.id.provider) {
            seen.append(source.id.provider)
        }

        return seen.map { provider in
            let states = sources
                .filter { $0.id.provider == provider }
                .compactMap { usage[$0.id]?.dominant(now: now) }
                .filter(\.hasData)
            let worst = states.max(by: { ($0.percent ?? 0) < ($1.percent ?? 0) }) ?? .unknown

            return segment(label: provider.shortLabel, state: worst, body: nil, thresholds)
        }
    }

    /// One segment per source — per account for Claude. `windows` decides
    /// whether the body is the dominant figure or every window it reports.
    private static func renderPerSource(
        _ usage: [SourceID: ProviderUsage],
        _ sources: [SourceDescriptor],
        _ thresholds: Thresholds,
        _ now: Date,
        windows: Bool
    ) -> LabelSpec {
        sources.map { source in
            let provided = usage[source.id] ?? .empty
            let dominant = provided.dominant(now: now)
            let body = windows
                ? provided.windows.map { $0.window.state(now: now).numberLabel }.joined(separator: "/")
                : nil

            return segment(label: source.shortLabel, state: dominant, body: body, thresholds)
        }
    }

    // MARK: - Formatting

    private static func segment(
        label: String,
        state: WindowState,
        body: String?,
        _ thresholds: Thresholds
    ) -> Segment {
        let severity = Severity.of(state.percent ?? 0, thresholds)
        let text: String
        if state.hasData {
            let figures = body ?? state.percentLabel
            text = "\(label) \(marker(severity))\(stalePrefix(state))\(figures)"
        } else {
            text = "\(label) —"
        }
        return Segment(
            text: text,
            severity: state.hasData ? severity : .normal,
            isStale: state.isStale,
            hasData: state.hasData
        )
    }

    /// Shown only when it carries information; a marker on every normal reading
    /// would just be noise.
    private static func marker(_ severity: Severity) -> String {
        severity == .normal ? "" : "\(severity.marker) "
    }

    private static func stalePrefix(_ state: WindowState) -> String {
        state.isStale ? "‹" : ""
    }
}
