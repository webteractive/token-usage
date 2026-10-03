import XCTest
@testable import TokenUsageCore

/// Every child this app starts must leave nothing behind: no open pipe
/// descriptors in this process and no surviving child. Leaked pipes exhaust a
/// machine-wide kernel limit, which is how this app once hung Xcode builds.
final class SubprocessLeakTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("subprocess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    /// Long enough for a freshly written script to start: macOS can take a few
    /// hundred milliseconds to launch an executable it has not seen before.
    private let slowTimeout: TimeInterval = 1.5

    private var pidFile: URL { directory.appendingPathComponent("pid") }

    private func script(_ name: String, _ body: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// Pipe descriptors open in this process right now.
    private func openPipeCount() -> Int {
        (0..<getdtablesize()).filter { descriptor in
            var info = stat()
            return fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFIFO
        }.count
    }

    private func recordedPID() throws -> pid_t {
        let text = try String(contentsOf: pidFile, encoding: .utf8)
        return try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    private func client(_ binary: String, timeout: TimeInterval = 5) -> CodexAppServerClient {
        CodexAppServerClient(timeout: timeout, killGrace: 0.2, locate: { binary })
    }

    private func rateLimitsResponse() throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/codex-ratelimits", withExtension: "json")
        )
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let line = try JSONSerialization.data(withJSONObject: ["id": 1, "result": result])
        return String(decoding: line, as: UTF8.self)
    }

    /// Answers like the real server, then stays up waiting for more requests.
    private func answeringServer(ignoringSIGTERM: Bool = false) throws -> String {
        try script("codex", """
        \(ignoringSIGTERM ? "trap '' TERM" : "")
        echo $$ > '\(pidFile.path)'
        echo '{"id":0,"result":{}}'
        echo '\(try rateLimitsResponse())'
        while :; do sleep 0.1; done
        """)
    }

    // MARK: - Codex app-server

    func testRepeatedFetchesLeaveNoPipesOpen() throws {
        let client = client(try answeringServer())
        _ = try client.fetch()
        let before = openPipeCount()

        for _ in 0..<20 {
            XCTAssertFalse(try client.fetch().windows.isEmpty)
        }

        XCTAssertEqual(openPipeCount(), before)
    }

    func testServerIgnoringSIGTERMIsKilledBeforeFetchReturns() throws {
        let client = client(try answeringServer(ignoringSIGTERM: true))

        _ = try client.fetch()

        XCTAssertFalse(isAlive(try recordedPID()))
    }

    /// The server that never answers is the one that used to pile up: the read
    /// blocked past its deadline, so the child was never terminated at all.
    func testSilentServerTimesOutAndIsKilled() throws {
        let binary = try script("codex", """
        trap '' TERM
        echo $$ > '\(pidFile.path)'
        while :; do sleep 0.1; done
        """)
        let before = openPipeCount()
        let started = Date()

        XCTAssertThrowsError(try client(binary, timeout: slowTimeout).fetch()) { error in
            XCTAssertEqual(error as? CodexAppServerError, .noResponse)
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertFalse(isAlive(try recordedPID()))
        XCTAssertEqual(openPipeCount(), before)
    }

    func testServerThatExitsAtOnceIsAnErrorNotACrash() throws {
        let binary = try script("codex", "exit 1")
        let before = openPipeCount()

        XCTAssertThrowsError(try client(binary).fetch())

        XCTAssertEqual(openPipeCount(), before)
    }

    // MARK: - Run-to-completion commands

    func testCaptureReturnsOutputAndLeavesNoPipesOpen() throws {
        let binary = try script("tool", "echo out; echo err >&2")
        _ = Subprocess.capture(binary, arguments: [], timeout: 5)
        let before = openPipeCount()

        for _ in 0..<20 {
            let result = try XCTUnwrap(Subprocess.capture(binary, arguments: [], timeout: 5))
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.output, Data("out\n".utf8))
        }

        XCTAssertEqual(openPipeCount(), before)
    }

    func testCaptureKillsACommandThatOutlivesItsTimeout() throws {
        let binary = try script("tool", """
        trap '' TERM
        echo $$ > '\(pidFile.path)'
        while :; do sleep 0.1; done
        """)
        let before = openPipeCount()

        let result = try XCTUnwrap(
            Subprocess.capture(binary, arguments: [], timeout: slowTimeout, killGrace: 0.2)
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(isAlive(try recordedPID()))
        XCTAssertEqual(openPipeCount(), before)
    }

    func testCaptureReturnsNilWhenTheBinaryIsMissing() {
        let before = openPipeCount()

        XCTAssertNil(Subprocess.capture("/nonexistent/tool", arguments: [], timeout: 1))

        XCTAssertEqual(openPipeCount(), before)
    }

    func testListingReturnsNilForAWedgedZetty() throws {
        let binary = try script("zetty", "echo '{\"partial\":'; while :; do sleep 0.1; done")

        XCTAssertNil(ClaudeAccountLocator.listing(binary: binary, timeout: slowTimeout))
    }

    func testListingReturnsZettyOutput() throws {
        let binary = try script("zetty", "echo '{\"accounts\":[]}'")

        XCTAssertEqual(
            ClaudeAccountLocator.listing(binary: binary, timeout: 5),
            Data("{\"accounts\":[]}\n".utf8)
        )
    }
}
