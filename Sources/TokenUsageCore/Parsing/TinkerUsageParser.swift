import Foundation

/// Parses the quota snapshot Tinker keeps beside its Claude login.
///
/// Tinker runs Claude Code with a statusline of its own, so its sessions never
/// reach this app's shim. This file is where their `rate_limits` land instead,
/// already reduced to the latest reading.
public enum TinkerUsageParser {

    private struct File: Decodable {
        struct Snapshot: Decodable {
            struct Window: Decodable {
                let usedPercentage: Double
                /// Epoch seconds.
                let resetsAt: Double
            }
            let fiveHour: Window?
            let sevenDay: Window?
        }
        let snapshot: Snapshot?
        /// Epoch seconds, with a fraction.
        let updatedAt: Double?
    }

    /// - Parameter modifiedAt: the file's modification date, used only when the
    ///   file does not say for itself when the reading was taken.
    public static func parse(_ data: Data, modifiedAt: Date) throws -> ProviderUsage {
        let file = try JSONDecoder().decode(File.self, from: data)
        // Absent before the first reply of the first chat, like the statusline
        // payload it is made from. That is "no data", not zero usage.
        guard let snapshot = file.snapshot else { return .empty }

        let observedAt = file.updatedAt.map(Date.init(timeIntervalSince1970:)) ?? modifiedAt
        return ProviderUsage(windows: [
            window(snapshot.fiveHour, kind: .session, observedAt: observedAt),
            window(snapshot.sevenDay, kind: .weeklyAll, observedAt: observedAt),
        ].compactMap { $0 })
    }

    private static func window(
        _ raw: File.Snapshot.Window?,
        kind: WindowKind,
        observedAt: Date
    ) -> QuotaWindow? {
        guard let raw else { return nil }
        return QuotaWindow(
            kind: kind,
            window: UsageWindow(
                usedPercent: raw.usedPercentage,
                resetsAt: Date(timeIntervalSince1970: raw.resetsAt),
                observedAt: observedAt
            ),
            isActive: false
        )
    }
}
