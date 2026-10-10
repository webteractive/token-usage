import XCTest
@testable import TokenUsageCore

final class PollScheduleTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_791_650_000)

    func testIsDueBeforeAnythingHasBeenAsked() {
        XCTAssertTrue(PollSchedule().isDue(now: now))
    }

    func testRestsForTheIntervalOnceARequestGoesOut() {
        var schedule = PollSchedule()
        schedule.began(now: now)

        XCTAssertFalse(schedule.isDue(now: now.addingTimeInterval(PollSchedule.interval - 1)))
        XCTAssertTrue(schedule.isDue(now: now.addingTimeInterval(PollSchedule.interval)))
    }

    /// Retrying a refusal on the next tick is what keeps the endpoint refusing.
    func testEachRefusalWaitsLongerUpToACap() {
        var schedule = PollSchedule()
        var waits: [TimeInterval] = []
        var clock = now

        for _ in 0..<5 {
            schedule.began(now: clock)
            schedule.refused(now: clock, retryAfter: nil)
            let wait = stride(from: 0, through: 7200, by: 60).first {
                schedule.isDue(now: clock.addingTimeInterval($0))
            } ?? .infinity
            waits.append(wait)
            clock = clock.addingTimeInterval(wait)
        }

        XCTAssertEqual(waits, [600, 1200, 1800, 1800, 1800])
    }

    func testHonoursALongerRetryAfter() {
        var schedule = PollSchedule()
        schedule.refused(now: now, retryAfter: 3600)

        XCTAssertFalse(schedule.isDue(now: now.addingTimeInterval(3599)))
        XCTAssertTrue(schedule.isDue(now: now.addingTimeInterval(3600)))
    }

    /// The endpoint sends short hints while it goes on refusing; they must not
    /// shorten the wait.
    func testIgnoresARetryAfterShorterThanTheBackoff() {
        var schedule = PollSchedule()
        schedule.refused(now: now, retryAfter: 5)

        XCTAssertFalse(schedule.isDue(now: now.addingTimeInterval(599)))
    }

    func testSuccessForgetsEarlierRefusals() {
        var schedule = PollSchedule()
        schedule.refused(now: now, retryAfter: nil)
        schedule.refused(now: now, retryAfter: nil)
        schedule.succeeded()

        let later = now.addingTimeInterval(7200)
        schedule.refused(now: later, retryAfter: nil)

        XCTAssertTrue(schedule.isDue(now: later.addingTimeInterval(600)))
    }

    /// A poll starting while a backoff is in force must not cut it short.
    func testBeginningDoesNotShortenABackoff() {
        var schedule = PollSchedule()
        schedule.refused(now: now, retryAfter: nil)
        schedule.began(now: now)

        XCTAssertFalse(schedule.isDue(now: now.addingTimeInterval(PollSchedule.interval)))
    }
}
