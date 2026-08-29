import XCTest
@testable import TokenUsageCore

final class FileWatcherTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tokenusage-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testFiresWhenAWatchedDirectoryChanges() throws {
        let fired = expectation(description: "change reported")
        let watcher = FileWatcher(urls: [directory]) { fired.fulfill() }
        watcher.start()
        defer { watcher.stop() }

        try Data("x".utf8).write(to: directory.appendingPathComponent("a.json"))

        wait(for: [fired], timeout: 5)
    }

    /// Writers touch a file several times in quick succession; the app should
    /// reparse once, not once per event.
    func testRapidChangesAreCoalesced() throws {
        let fired = expectation(description: "change reported")
        fired.assertForOverFulfill = false

        let count = NSMutableArray()
        let watcher = FileWatcher(urls: [directory], debounce: 0.4) {
            count.add(1)
            fired.fulfill()
        }
        watcher.start()
        defer { watcher.stop() }

        for i in 0..<10 {
            try Data("x".utf8).write(to: directory.appendingPathComponent("f\(i).json"))
        }

        wait(for: [fired], timeout: 5)
        // Let the debounce window close before counting.
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertLessThan(count.count, 10)
    }

    func testStopEndsNotifications() throws {
        let watcher = FileWatcher(urls: [directory]) {
            XCTFail("callback fired after stop")
        }
        watcher.start()
        watcher.stop()

        try Data("x".utf8).write(to: directory.appendingPathComponent("a.json"))
        Thread.sleep(forTimeInterval: 1.0)
    }
}
