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
    ///   own, and the shim rewrites a session's file only when the API has
    ///   answered again, so the date on disk is the date of the reading.
    /// - Parameter configDirectory: the Claude config directory the reading is
    ///   for. Any login whose settings point at the shim writes the same file —
    ///   a zetty account created by copying `~/.claude/settings.json` does — so
    ///   a payload is accepted only when its transcript lives inside this
    ///   directory, and one that cannot be attributed is not accepted at all.
    public static func parse(_ data: Data, observedAt: Date, configDirectory: URL) throws -> ProviderUsage {
        let capture = try capture(data, observedAt: observedAt)
        guard capture.isInside(root(of: configDirectory)) else { throw ParseError.otherAccount }
        return capture.usage
    }

    /// One session's payload, decoded but not yet attributed to a login. The
    /// two are kept apart so a directory holding every session's capture can be
    /// decoded once and then asked about each login in turn.
    public struct Capture: Equatable, Sendable {
        public let usage: ProviderUsage
        /// Symlinks already resolved. `nil` when the payload named no
        /// transcript, which leaves nothing to attribute it by.
        let transcriptPath: String?

        /// - Parameter root: a config directory as returned by `root(of:)`.
        public func isInside(_ root: String) -> Bool {
            transcriptPath?.hasPrefix(root) ?? false
        }
    }

    public static func capture(_ data: Data, observedAt: Date) throws -> Capture {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return Capture(
            usage: usage(from: payload.rate_limits, observedAt: observedAt),
            transcriptPath: payload.transcript_path.map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
            }
        )
    }

    /// A config directory in the form captures are matched against: symlinks
    /// resolved, because a dotfiles-managed `~/.claude` may be reported through
    /// either name, and a trailing separator, so `~/.claude-work` is not taken
    /// to be inside `~/.claude`.
    public static func root(of configDirectory: URL) -> String {
        let path = configDirectory.resolvingSymlinksInPath().path
        return path.hasSuffix("/") ? path : path + "/"
    }

    private static func usage(from limits: Payload.RateLimits?, observedAt: Date) -> ProviderUsage {
        guard let limits else {
            // Documented as subscriber-only. Absence is normal, not an error,
            // and must surface as "no data" rather than zero usage.
            return .empty
        }

        // The statusline payload carries only these two windows. Scoped weekly
        // limits exist but are not exposed here, which is what the usage API
        // is still polled for.
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
}
