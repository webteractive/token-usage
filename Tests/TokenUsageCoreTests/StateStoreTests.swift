import XCTest
@testable import TokenUsageCore

final class StateStoreTests: XCTestCase {

    private var home: URL!
    private var store: StateStore!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tokenusage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        store = StateStore(paths: Paths(home: home))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testWriteThenReadRoundTrips() throws {
        let url = store.paths.codexState
        try store.write(Data(#"{"a":1}"#.utf8), to: url)
        let result = try store.read(url)
        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), #"{"a":1}"#)
    }

    func testWriteCreatesStateDirectory() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths.stateDirectory.path))
        try store.write(Data("x".utf8), to: store.paths.codexState)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths.stateDirectory.path))
    }

    func testReadReportsModificationDate() throws {
        let url = store.paths.codexState
        try store.write(Data("x".utf8), to: url)
        let result = try store.read(url)
        XCTAssertEqual(result.modifiedAt.timeIntervalSinceNow, 0, accuracy: 5)
    }

    /// The raw Claude payload carries session metadata, so it must not be
    /// world-readable.
    func testWrittenFileIsOwnerOnly() throws {
        let url = store.paths.claudeRawState
        try store.write(Data("x".utf8), to: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attrs[.posixPermissions] as? NSNumber, 0o600)
    }

    func testOverwriteReplacesContent() throws {
        let url = store.paths.codexState
        try store.write(Data("first".utf8), to: url)
        try store.write(Data("second".utf8), to: url)
        XCTAssertEqual(String(decoding: try store.read(url).data, as: UTF8.self), "second")
    }

    func testReadMissingFileThrows() {
        XCTAssertThrowsError(try store.read(store.paths.codexState))
    }

    func testExists() throws {
        XCTAssertFalse(store.exists(store.paths.codexState))
        try store.write(Data("x".utf8), to: store.paths.codexState)
        XCTAssertTrue(store.exists(store.paths.codexState))
    }

    func testPathsAreRootedAtGivenHome() {
        let paths = Paths(home: URL(fileURLWithPath: "/tmp/fakehome"))
        XCTAssertEqual(
            paths.claudeSettings.path,
            "/tmp/fakehome/.claude/settings.json"
        )
        XCTAssertEqual(paths.shimScript.path, "/tmp/fakehome/.claude/tokenusage-shim.sh")
        XCTAssertEqual(paths.codexSessions.path, "/tmp/fakehome/.codex/sessions")
    }
}
