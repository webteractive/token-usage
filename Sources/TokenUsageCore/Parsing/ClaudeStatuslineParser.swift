import Foundation

/// Parses the JSON Claude Code writes to stdin of the configured statusline
/// command. This is the only place Claude's quota exists locally — it is never
/// written to the session JSONL, which is why searching there finds nothing.
public enum ClaudeStatuslineParser {

    public enum ParseError: Error, Equatable {
        /// The payload came from a Claude login other than the one asked about.
        case otherAccount
    }

    private struct Payload: Decodable {
        struct RateLimits: Decodable {
            struct Window: Decodable {
                let used_percentage: Double
                let resets_at: Double
            }
            let five_hour: Window?
            let seven_day: Window?
        }
        let rate_limits: RateLimits?
        let transcript_path: String?
    }

    /// - Parameter observedAt: when the payload was written (the state file's
    ///   modification date). The statusline payload carries no timestamp of its
    ///   own, so freshness is judged by when it landed on disk.
    /// - Parameter configDirectory: the Claude config directory the reading is
    ///   for. Any login whose settings point at the shim writes the same file —
    ///   a zetty account created by copying `~/.claude/settings.json` does — so
    ///   a payload is accepted only when its transcript lives inside this
    ///   directory, and one that cannot be attributed is not accepted at all.
    public static func parse(_ data: Data, observedAt: Date, configDirectory: URL) throws -> ProviderUsage {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let transcript = payload.transcript_path,
              isPath(transcript, inside: configDirectory)
        else { throw ParseError.otherAccount }

        guard let limits = payload.rate_limits else {
            // Documented as subscriber-only. Absence is normal, not an error,
            // and must surface as "no data" rather than zero usage.
            return .empty
        }

        // The statusline payload carries only these two windows. Scoped weekly
        // limits exist but are not exposed here — that is precisely why this is
        // the fallback source and the usage API is preferred.
        return ProviderUsage(windows: [
            window(limits.five_hour, kind: .session, observedAt: observedAt),
            window(limits.seven_day, kind: .weeklyAll, observedAt: observedAt),
        ].compactMap { $0 })
    }

    private static func window(
        _ raw: Payload.RateLimits.Window?,
        kind: WindowKind,
        observedAt: Date
    ) -> QuotaWindow? {
        guard let raw else { return nil }
        return QuotaWindow(
            kind: kind,
            window: UsageWindow(
                usedPercent: raw.used_percentage,
                resetsAt: Date(timeIntervalSince1970: raw.resets_at),
                observedAt: observedAt
            ),
            isActive: false
        )
    }

    /// Compared with a trailing separator so `~/.claude-work` is not taken to be
    /// inside `~/.claude`. Symlinks are resolved on both sides because a
    /// dotfiles-managed `~/.claude` may be reported through either name.
    private static func isPath(_ path: String, inside directory: URL) -> Bool {
        let root = directory.resolvingSymlinksInPath().path
        let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
