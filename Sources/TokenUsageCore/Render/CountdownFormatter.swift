import Foundation

public enum CountdownFormatter {

    /// Countdowns render in local time; resets_at is epoch UTC, so this keeps
    /// them right across timezone changes and DST.
    public static func reset(for window: UsageWindow?, now: Date) -> String {
        guard let window else { return "no data" }
        let interval = window.resetsAt.timeIntervalSince(now)
        if interval <= 0 {
            return "window reset \(duration(-interval)) ago"
        }
        return "resets in \(duration(interval))"
    }

    /// Only stale readings need an "as of" — a live one is current by
    /// definition, and a reset one is certain regardless of its age.
    public static func observed(_ state: WindowState) -> String? {
        guard case .stale(_, let since) = state else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return "as of \(formatter.string(from: since))"
    }

    private static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60

        // A zero trailing component reads badly ("3h 0m ago"), so it is dropped.
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }
}
