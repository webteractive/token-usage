import XCTest
@testable import TokenUsageCore

final class ShimInstallerTests: XCTestCase {

    private var home: URL!
    private var paths: Paths!
    private var installer: ShimInstaller!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tokenusage-shim-\(UUID().uuidString)")
        paths = Paths(home: home)
        installer = ShimInstaller(paths: paths)
        try FileManager.default.createDirectory(at: paths.claudeDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func writeSettings(_ json: String) throws {
        try Data(json.utf8).write(to: paths.claudeSettings)
    }

    private func settingsJSON(command: String) throws -> String {
        let object = ["statusLine": ["command": command, "type": "command"]]
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func settingsCommand() throws -> String? {
        let data = try Data(contentsOf: paths.claudeSettings)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let statusLine = object?["statusLine"] as? [String: Any]
        return statusLine?["command"] as? String
    }

    // MARK: - Status detection

    func testStatusWithNoSettingsIsNotInstalled() {
        XCTAssertEqual(installer.status(), .notInstalled(existingCommand: nil))
    }

    func testStatusDetectsExistingCommand() throws {
        try writeSettings(#"{"statusLine":{"command":"~/.claude/statusline.sh","type":"command"}}"#)
        XCTAssertEqual(installer.status(), .notInstalled(existingCommand: "~/.claude/statusline.sh"))
    }

    func testStatusAfterInstallReportsDelegate() throws {
        try writeSettings(#"{"statusLine":{"command":"~/.claude/statusline.sh","type":"command"}}"#)
        try installer.install()
        XCTAssertEqual(installer.status(), .installed(delegate: "~/.claude/statusline.sh"))
    }

    /// If the user rewires statusLine.command by hand we must notice and ask,
    /// not silently wrap or clobber their change.
    func testStatusDetectsExternalModification() throws {
        try writeSettings(#"{"statusLine":{"command":"~/.claude/statusline.sh","type":"command"}}"#)
        try installer.install()
        try writeSettings(#"{"statusLine":{"command":"/usr/local/bin/other","type":"command"}}"#)
        XCTAssertEqual(installer.status(), .modifiedExternally(current: "/usr/local/bin/other"))
    }

    // MARK: - Install

    func testInstallPointsSettingsAtShim() throws {
        try writeSettings(#"{"statusLine":{"command":"~/.claude/statusline.sh","type":"command"}}"#)
        try installer.install()
        XCTAssertEqual(try settingsCommand(), paths.shimScript.path)
    }

    func testInstallWritesExecutableShim() throws {
        try writeSettings("{}")
        try installer.install()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: paths.shimScript.path))
    }

    func testInstalledShimHasNoUnreplacedPlaceholders() throws {
        try writeSettings(#"{"statusLine":{"command":"~/.claude/statusline.sh","type":"command"}}"#)
        try installer.install()
        let script = try String(contentsOf: paths.shimScript, encoding: .utf8)
        XCTAssertFalse(script.contains("__STATE_DIR__"))
        XCTAssertFalse(script.contains("__DELEGATE_FILE__"))
        XCTAssertTrue(script.contains(paths.claudeSessions.path))
        XCTAssertEqual(try String(contentsOf: paths.shimDelegateFile, encoding: .utf8), "~/.claude/statusline.sh")
    }

    func testInstallBacksUpSettings() throws {
        let original = #"{"statusLine":{"command":"~/.claude/statusline.sh","type":"command"}}"#
        try writeSettings(original)
        try installer.install()
        let backup = try String(contentsOf: paths.claudeSettingsBackup, encoding: .utf8)
        XCTAssertEqual(backup, original)
    }

    func testInstallPreservesOtherSettingsKeys() throws {
        try writeSettings(#"{"hooks":{"Stop":[]},"statusLine":{"command":"a","type":"command"}}"#)
        try installer.install()
        let data = try Data(contentsOf: paths.claudeSettings)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["hooks"])
    }

    func testInstallWithNoExistingStatuslineLeavesDelegateEmpty() throws {
        try writeSettings("{}")
        try installer.install()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.shimDelegateFile.path))
        XCTAssertEqual(installer.status(), .installed(delegate: nil))
    }

    /// Installing twice must not wrap the shim around itself.
    func testInstallIsIdempotent() throws {
        try writeSettings(#"{"statusLine":{"command":"~/.claude/statusline.sh","type":"command"}}"#)
        try installer.install()
        try installer.install()
        XCTAssertEqual(installer.status(), .installed(delegate: "~/.claude/statusline.sh"))
        XCTAssertEqual(try settingsCommand(), paths.shimScript.path)
    }

    // MARK: - Uninstall

    func testUninstallRestoresOriginalCommand() throws {
        try writeSettings(#"{"statusLine":{"command":"~/.claude/statusline.sh","type":"command"}}"#)
        try installer.install()
        try installer.uninstall()
        XCTAssertEqual(try settingsCommand(), "~/.claude/statusline.sh")
        XCTAssertEqual(installer.status(), .notInstalled(existingCommand: "~/.claude/statusline.sh"))
    }

    func testUninstallRemovesShimScript() throws {
        try writeSettings("{}")
        try installer.install()
        try installer.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.shimScript.path))
    }

    func testUninstallWithNoOriginalRemovesStatusLineKey() throws {
        try writeSettings("{}")
        try installer.install()
        try installer.uninstall()
        XCTAssertNil(try settingsCommand())
    }

    /// Claude Code's own documented statusline example is an inline command
    /// containing both double quotes and $(...). Baking that into the shim
    /// would corrupt the script or expand at assignment time, so the delegate
    /// is stored as data instead. Asserts stdin still arrives intact.
    func testDelegateContainingQuotesAndSubstitutionStillReceivesStdin() throws {
        let real = paths.claudeDirectory.appendingPathComponent("real.sh")
        try Data("#!/bin/sh\ncat | sed 's/^/GOT:/'\n".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)

        // Quotes, a command substitution, and a variable reference.
        let tricky = #"marker="$(echo hi)"; \#(real.path)"#
        try writeSettings(try settingsJSON(command: tricky))
        try installer.install()

        // The script itself must not contain the delegate text at all.
        let script = try String(contentsOf: paths.shimScript, encoding: .utf8)
        XCTAssertFalse(script.contains("$(echo hi)"))
        XCTAssertFalse(script.contains("__DELEGATE_FILE__"))

        XCTAssertEqual(installer.status(), .installed(delegate: tricky))

        let payload = #"{"session_id":"s1","rate_limits":{"five_hour":{"used_percentage":47,"resets_at":1}}}"#
        let output = try run(paths.shimScript.path, stdin: payload)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "GOT:\(payload)")
        XCTAssertEqual(try captured("s1"), payload)
    }

    func testUninstallRemovesDelegateSidecar() throws {
        try writeSettings(#"{"statusLine":{"command":"~/.claude/statusline.sh","type":"command"}}"#)
        try installer.install()
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.shimDelegateFile.path))
        try installer.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.shimDelegateFile.path))
    }

    // MARK: - Behaviour of the installed shim

    /// The contract that matters most: the user's statusline output must survive
    /// the shim byte for byte.
    func testShimPassesStdinThroughUnchanged() throws {
        let delegate = paths.claudeDirectory.appendingPathComponent("fake-statusline.sh")
        try Data("#!/bin/sh\ncat | sed 's/^/OUT:/'\n".utf8).write(to: delegate)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: delegate.path)
        try writeSettings(#"{"statusLine":{"command":"\#(delegate.path)","type":"command"}}"#)
        try installer.install()

        let payload = #"{"rate_limits":{"five_hour":{"used_percentage":47,"resets_at":1787845497}}}"#
        let output = try run(paths.shimScript.path, stdin: payload)

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "OUT:\(payload)")
    }

    private func payload(session: String, sevenDay: Int, apiMs: Int, wallMs: Int = 0) -> String {
        // Spaced the way a pretty-printer would, and with a nested limit, since
        // the shim finds its way around this with patterns rather than a parser.
        """
        {"session_id": "\(session)", "cost": {"total_duration_ms": \(wallMs), "total_api_duration_ms": \(apiMs)},
         "rate_limits": {"seven_day": {"used_percentage": \(sevenDay), "resets_at": 1791702000}}}
        """
    }

    private func captured(_ session: String) throws -> String {
        try String(contentsOf: captureURL(session), encoding: .utf8)
    }

    private func captureURL(_ session: String) -> URL {
        paths.claudeSessions.appendingPathComponent("\(session).json")
    }

    private func backdate(_ session: String) throws -> Date {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: captureURL(session).path
        )
        return date
    }

    private func modificationDate(_ session: String) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: captureURL(session).path)[.modificationDate] as? Date
    }

    func testShimCapturesPayloadToStateFile() throws {
        try writeSettings("{}")
        try installer.install()

        let payload = payload(session: "0afd1d8e-4a37", sevenDay: 19, apiMs: 100)
        _ = try run(paths.shimScript.path, stdin: payload)

        XCTAssertEqual(try captured("0afd1d8e-4a37"), payload)
    }

    /// Sessions of one login each know the quota as of their own last request.
    /// Sharing a file is how the one that rendered last hid the one that knew
    /// the most.
    func testShimKeepsEachSessionsPayloadApart() throws {
        try writeSettings("{}")
        try installer.install()

        let idle = payload(session: "idle", sevenDay: 19, apiMs: 100)
        let busy = payload(session: "busy", sevenDay: 75, apiMs: 900)
        _ = try run(paths.shimScript.path, stdin: busy)
        _ = try run(paths.shimScript.path, stdin: idle)

        XCTAssertEqual(try captured("busy"), busy)
        XCTAssertEqual(try captured("idle"), idle)
    }

    /// An idle session re-renders every few seconds with the same figures.
    /// Touching the file then would date a days-old reading as current.
    func testShimLeavesAnIdleSessionsFileAlone() throws {
        try writeSettings("{}")
        try installer.install()

        _ = try run(paths.shimScript.path, stdin: payload(session: "s", sevenDay: 19, apiMs: 100, wallMs: 1))
        let written = try backdate("s")
        _ = try run(paths.shimScript.path, stdin: payload(session: "s", sevenDay: 19, apiMs: 100, wallMs: 99))

        XCTAssertEqual(try modificationDate("s"), written)
    }

    func testShimRewritesWhenTheFiguresMove() throws {
        try writeSettings("{}")
        try installer.install()

        _ = try run(paths.shimScript.path, stdin: payload(session: "s", sevenDay: 19, apiMs: 100))
        let written = try backdate("s")
        let moved = payload(session: "s", sevenDay: 20, apiMs: 100)
        _ = try run(paths.shimScript.path, stdin: moved)

        XCTAssertNotEqual(try modificationDate("s"), written)
        XCTAssertEqual(try captured("s"), moved)
    }

    /// A working session whose percentage has not ticked over is still being
    /// told the figure again, and must not be dimmed as stale.
    func testShimRewritesWhenTheAPIAnswersAgainWithTheSameFigures() throws {
        try writeSettings("{}")
        try installer.install()

        _ = try run(paths.shimScript.path, stdin: payload(session: "s", sevenDay: 19, apiMs: 100))
        let written = try backdate("s")
        _ = try run(paths.shimScript.path, stdin: payload(session: "s", sevenDay: 19, apiMs: 250))

        XCTAssertNotEqual(try modificationDate("s"), written)
    }

    /// A payload naming no session cannot be filed, and one whose id is not a
    /// plain token must never become a path.
    func testShimCapturesNothingWithoutAUsableSessionID() throws {
        try writeSettings("{}")
        try installer.install()

        _ = try run(paths.shimScript.path, stdin: #"{"rate_limits":{"seven_day":{"used_percentage":1,"resets_at":1}}}"#)
        _ = try run(paths.shimScript.path, stdin: #"{"session_id":"../../escape","rate_limits":{}}"#)

        let written = (try? FileManager.default.contentsOfDirectory(atPath: paths.claudeSessions.path)) ?? []
        XCTAssertEqual(written, [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.stateDirectory.appendingPathComponent("escape.json").path
        ))
    }

    // MARK: - Upgrading an installed shim

    /// Sessions run whatever script is on disk, so a build that changes the
    /// shim has to replace the installed copy itself.
    func testRefreshScriptReplacesAnOutdatedShim() throws {
        try writeSettings(#"{"statusLine":{"command":"~/.claude/statusline.sh","type":"command"}}"#)
        try installer.install()
        let current = try String(contentsOf: paths.shimScript, encoding: .utf8)
        try Data("#!/bin/sh\n# an older build's shim\n".utf8).write(to: paths.shimScript)
        try FileManager.default.createDirectory(at: paths.stateDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: paths.claudeRawState)

        XCTAssertTrue(try installer.refreshScript())

        XCTAssertEqual(try String(contentsOf: paths.shimScript, encoding: .utf8), current)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: paths.shimScript.path))
        XCTAssertEqual(installer.status(), .installed(delegate: "~/.claude/statusline.sh"))
        // The shared capture the old shim wrote would only go stale.
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.claudeRawState.path))
    }

    func testRefreshScriptLeavesACurrentShimAlone() throws {
        try writeSettings("{}")
        try installer.install()

        XCTAssertFalse(try installer.refreshScript())
    }

    /// Never installs on its own: wiring the shim into settings is the user's call.
    func testRefreshScriptDoesNothingWhenNotInstalled() throws {
        try writeSettings("{}")

        XCTAssertFalse(try installer.refreshScript())
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.shimScript.path))
        XCTAssertNil(try settingsCommand())
    }

    /// If the state write fails, the user's statusline must still run.
    func testShimDelegatesEvenWhenStateWriteFails() throws {
        let delegate = paths.claudeDirectory.appendingPathComponent("fake-statusline.sh")
        try Data("#!/bin/sh\ncat >/dev/null; echo DELEGATED\n".utf8).write(to: delegate)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: delegate.path)
        try writeSettings(#"{"statusLine":{"command":"\#(delegate.path)","type":"command"}}"#)
        try installer.install()

        // Make the state directory unwritable.
        try FileManager.default.createDirectory(at: paths.stateDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: paths.stateDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: paths.stateDirectory.path
            )
        }

        let output = try run(paths.shimScript.path, stdin: "{}")
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "DELEGATED")
    }

    // MARK: - Helper

    private func run(_ path: String, stdin: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [path]

        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()

        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(decoding: data, as: UTF8.self)
    }
}
