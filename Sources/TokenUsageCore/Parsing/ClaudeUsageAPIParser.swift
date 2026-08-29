import Foundation

/// Parses the response of Claude's OAuth usage endpoint.
///
/// Preferred over the statusline payload because it is complete — it includes
/// scoped weekly limits (per-model caps) that the statusline never carries —
/// and because it is live rather than only arriving while a session runs.
public enum ClaudeUsageAPIParser {

    private struct Response: Decodable {
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable { let display_name: String? }
                let model: Model?
            }
            let kind: String
            let percent: Double
            let resets_at: String?
            let scope: Scope?
            let is_active: Bool?
        }
        let limits: [Limit]?
    }

    public static func parse(_ data: Data, observedAt: Date) throws -> ProviderUsage {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let limits = response.limits else { return .empty }

        return ProviderUsage(windows: limits.compactMap { limit in
            // No reset means no countdown, and inventing one would be a lie.
            guard let raw = limit.resets_at, let resetsAt = date(from: raw) else { return nil }
            return QuotaWindow(
                kind: kind(for: limit),
                window: UsageWindow(
                    usedPercent: limit.percent,
                    resetsAt: resetsAt,
                    observedAt: observedAt
                ),
                isActive: limit.is_active ?? false
            )
        })
    }

    /// Unknown kinds are preserved rather than dropped: the endpoint returns an
    /// open-ended list, and silently discarding a limit is how you fail to warn
    /// someone about the one that is about to block them.
    private static func kind(for limit: Response.Limit) -> WindowKind {
        switch limit.kind {
        case "session": .session
        case "weekly_all": .weeklyAll
        case "weekly_scoped":
            .weeklyScoped(model: limit.scope?.model?.display_name ?? "scoped")
        default: .other(limit.kind)
        }
    }

    /// The endpoint returns ISO8601 with fractional seconds and an offset,
    /// unlike the statusline's epoch seconds.
    private static func date(from raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
