import Foundation

/// Decides when one login's token may next be used against the usage endpoint.
///
/// The endpoint throttles each token separately and goes on answering 429 for
/// as long as it keeps being asked, so a refusal has to widen the gap rather
/// than be retried on the next tick. Polling it every minute is what once left
/// two logins refused for most of a day.
public struct PollSchedule: Equatable, Sendable {

    public static let interval: TimeInterval = 300
    public static let longestBackoff: TimeInterval = 1800

    private var nextAttempt = Date.distantPast
    private var refusals = 0

    public init() {}

    public func isDue(now: Date) -> Bool { now >= nextAttempt }

    /// Called before a request goes out, so overlapping refreshes cannot both
    /// send one. Never shortens a backoff already in force.
    public mutating func began(now: Date) {
        nextAttempt = max(nextAttempt, now.addingTimeInterval(Self.interval))
    }

    public mutating func succeeded() {
        refusals = 0
    }

    /// - Parameter retryAfter: the server's own hint, honoured when it asks for
    ///   longer than the backoff would have waited anyway.
    public mutating func refused(now: Date, retryAfter: TimeInterval?) {
        refusals += 1
        let backoff = min(Self.interval * pow(2, Double(refusals)), Self.longestBackoff)
        nextAttempt = now.addingTimeInterval(max(backoff, retryAfter ?? 0))
    }
}
