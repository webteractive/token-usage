import Foundation

public enum MenuBarLabelRenderer {

    /// Sources arrive in a fixed order resolved at discovery, so the bar does
    /// not reshuffle as numbers change.
    public static func render(
        usage: [SourceID: ProviderUsage],
        sources: [SourceDescriptor],
        mode: DisplayMode,
        thresholds: Thresholds = .default,
        /// Drops sources that have never reported from the per-source modes.
        /// They stay in the dropdown, badge and all, so this hides noise rather
        /// than information.
        hidesEmptySources: Bool,
        now: Date
    ) -> LabelSpec {
        switch mode {
        case .worstOf:
            renderWorstOf(usage, sources, thresholds, now)
        case .perTool:
            // Deliberately unfiltered: a whole vendor going quiet is worth
            // saying out loud, unlike one login among several.
            renderPerTool(usage, sources, thresholds, now)
        case .perAccount:
            renderPerSource(usage, sources, thresholds, now, windows: false, hiding: hidesEmptySources)
        case .full:
            renderPerSource(usage, sources, thresholds, now, windows: true, hiding: hidesEmptySources)
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
            return [noData]
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
        windows: Bool,
        hiding: Bool
    ) -> LabelSpec {
        let segments = sources.map { source in
            let provided = usage[source.id] ?? .empty
            let dominant = provided.dominant(now: now)
            let body = windows
                ? provided.windows.map { $0.window.state(now: now).numberLabel }.joined(separator: "/")
                : nil

            return segment(label: source.shortLabel, state: dominant, body: body, thresholds)
        }

        guard hiding else { return segments }

        // An empty menu bar item would be invisible and unclickable, so a
        // machine where nothing has reported still shows one em dash.
        let reporting = segments.filter(\.hasData)
        return reporting.isEmpty ? [noData] : reporting
    }

    /// The reading for "never reported". The em dash is load-bearing: it must
    /// never be rendered as 0%.
    private static var noData: Segment {
        Segment(text: "—", severity: .normal, isStale: false, hasData: false)
    }

    // MARK: - Formatting

    private static func segment(
        label: String,
        state: WindowState,
        body: String?,
        _ thresholds: Thresholds
    ) -> Segment {
        // Unwrapping once rather than reaching for a `?? 0` sentinel: a reading
        // that never arrived has no severity, and must never read as 0%.
        guard let percent = state.percent else {
            return Segment(text: "\(label) —", severity: .normal, isStale: state.isStale, hasData: false)
        }
        let severity = Severity.of(percent, thresholds)
        return Segment(
            text: "\(label) \(marker(severity))\(stalePrefix(state))\(body ?? state.percentLabel)",
            severity: severity,
            isStale: state.isStale,
            hasData: true
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
