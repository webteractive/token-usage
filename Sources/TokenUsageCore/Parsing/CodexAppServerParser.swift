import Foundation

/// Parses the `account/rateLimits/read` result from the Codex app-server.
///
/// Preferred over the rollout files because it is live, and because it carries
/// `rateLimitsByLimitId` — scoped buckets such as `base_model_inference` that
/// never appear in a session file. Missing a scoped bucket is the same blind
/// spot that hid Claude's per-model weekly cap.
public enum CodexAppServerParser {

    /// The bucket representing overall Codex usage; every other bucket is a
    /// scoped limit shown alongside it.
    private static let mainBucket = "codex"

    private struct Result: Decodable {
        struct Snapshot: Decodable {
            struct Window: Decodable {
                let usedPercent: Double
                let resetsAt: Double?
            }
            let limitId: String?
            let limitName: String?
            let primary: Window?
            let secondary: Window?
        }
        let rateLimits: Snapshot?
        let rateLimitsByLimitId: [String: Snapshot]?
    }

    public static func parse(_ data: Data, observedAt: Date) throws -> ProviderUsage {
        let result = try JSONDecoder().decode(Result.self, from: data)

        // Older app-server versions send only the single-bucket view.
        guard let buckets = result.rateLimitsByLimitId, !buckets.isEmpty else {
            guard let single = result.rateLimits else { return .empty }
            return ProviderUsage(windows: mainWindows(single, observedAt: observedAt))
        }

        return ProviderUsage(windows: buckets.flatMap { id, snapshot -> [QuotaWindow] in
            guard id != mainBucket else { return mainWindows(snapshot, observedAt: observedAt) }
            // Anything that is not the main bucket is a scoped limit; the
            // server names it, so nothing here is hardcoded per model.
            let label = snapshot.limitName ?? snapshot.limitId ?? id
            return [snapshot.primary, snapshot.secondary].compactMap {
                window($0, kind: .weeklyScoped(model: label), observedAt: observedAt)
            }
        })
    }

    private static func mainWindows(
        _ snapshot: Result.Snapshot,
        observedAt: Date
    ) -> [QuotaWindow] {
        [
            window(snapshot.primary, kind: .session, observedAt: observedAt),
            window(snapshot.secondary, kind: .weeklyAll, observedAt: observedAt),
        ].compactMap { $0 }
    }

    private static func window(
        _ raw: Result.Snapshot.Window?,
        kind: WindowKind,
        observedAt: Date
    ) -> QuotaWindow? {
        // No reset means no countdown, and inventing one would be a lie.
        guard let raw, let resetsAt = raw.resetsAt else { return nil }
        return QuotaWindow(
            kind: kind,
            window: UsageWindow(
                usedPercent: raw.usedPercent,
                resetsAt: Date(timeIntervalSince1970: resetsAt),
                observedAt: observedAt
            ),
            isActive: false
        )
    }
}
