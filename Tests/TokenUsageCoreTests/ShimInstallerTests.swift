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
        XCTAssertFalse(script.contains("__STATE_FILE__"))
        XCTAssertFalse(script.contains("__DELEGATE__"))
        XCTAssertTrue(script.contains(paths.claudeRawState.path))
        XCTAssertTrue(script.contains("~/.claude/statusline.sh"))
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
        let script = try String(contentsOf: paths.shimScript, encoding: .utf8)
        XCTAssertTrue(script.contains(#"delegate=""#))
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

    func testShimCapturesPayloadToStateFile() throws {
        try writeSettings("{}")
        try installer.install()

        let payload = #"{"rate_limits":{"five_hour":{"used_percentage":47,"resets_at":1787845497}}}"#
        _ = try run(paths.shimScript.path, stdin: payload)

        let captured = try String(contentsOf: paths.claudeRawState, encoding: .utf8)
        XCTAssertEqual(captured, payload)
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
