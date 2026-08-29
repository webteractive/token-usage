import Foundation

extension ISO8601DateFormatter {
    /// Codex timestamps carry fractional seconds, which the default
    /// configuration rejects.
    ///
    /// Built per call rather than shared: ISO8601DateFormatter is not Sendable,
    /// and parsing runs about once per refresh, so a fresh instance costs
    /// nothing and avoids an unchecked concurrency claim.
    static var codexParser: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}

/// Reads the most recent quota reading out of a tail chunk of a Codex rollout
/// file. Codex persists `rate_limits` on `token_count` events, so unlike Claude
/// this data is available directly from disk.
public enum CodexRolloutParser {

    private struct Line: Decodable {
        struct Payload: Decodable {
            struct RateLimits: Decodable {
                struct Window: Decodable {
                    let used_percent: Double
                    let resets_at: Double
                }
                let primary: Window?
                let secondary: Window?
            }
            let rate_limits: RateLimits?
        }
        let timestamp: String?
        let payload: Payload?
    }

    /// - Parameter chunk: the tail of a rollout file. Its first line is usually
    ///   truncated mid-JSON by the fixed-size read; no special handling is
    ///   needed because a partial line simply fails to decode and is skipped.
    /// - Returns: the last complete reading, or nil if the chunk holds none.
    public static func parseLatest(chunk: String) -> ProviderUsage? {
        // Scan backwards: the newest reading wins, and stopping at the first
        // hit avoids decoding the whole chunk.
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard
                let decoded = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)),
                let limits = decoded.payload?.rate_limits,
                limits.primary != nil || limits.secondary != nil
            else { continue }

            let observedAt = decoded.timestamp
                .flatMap(ISO8601DateFormatter.codexParser.date(from:))
                ?? Date()

            return ProviderUsage(windows: [
                window(limits.primary, kind: .session, observedAt: observedAt),
                window(limits.secondary, kind: .weeklyAll, observedAt: observedAt),
            ].compactMap { $0 })
        }
        return nil
    }

    private static func window(
        _ raw: Line.Payload.RateLimits.Window?,
        kind: WindowKind,
        observedAt: Date
    ) -> QuotaWindow? {
        guard let raw else { return nil }
        return QuotaWindow(
            kind: kind,
            window: UsageWindow(
                usedPercent: raw.used_percent,
                resetsAt: Date(timeIntervalSince1970: raw.resets_at),
                observedAt: observedAt
            ),
            isActive: false
        )
    }
}
