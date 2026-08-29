import Foundation

public enum ShimStatus: Equatable, Sendable {
    /// The shim is not wired up. Carries whatever statusline the user already has.
    case notInstalled(existingCommand: String?)
    /// The shim is wired up and delegates to `delegate` (nil when the user had none).
    case installed(delegate: String?)
    /// The shim script exists but settings point elsewhere — the user rewired it
    /// by hand. Do not clobber; ask.
    case modifiedExternally(current: String)
}

public enum ShimInstallError: Error, Equatable {
    case templateMissing
}

/// Installs and removes the statusline shim.
///
/// The only component that edits user configuration, and the only one that can
/// break the user's terminal, so it backs up `settings.json` before every write
/// and restores it verbatim on uninstall.
public struct ShimInstaller: Sendable {
    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    // MARK: - Status

    public func status() -> ShimStatus {
        let current = currentCommand()
        let shimPath = paths.shimScript.path

        guard FileManager.default.fileExists(atPath: shimPath) else {
            return .notInstalled(existingCommand: current)
        }
        guard current == shimPath else {
            if let current { return .modifiedExternally(current: current) }
            return .notInstalled(existingCommand: nil)
        }
        return .installed(delegate: installedDelegate())
    }

    // MARK: - Install

    public func install() throws {
        let delegate: String?
        switch status() {
        case .installed(let existing):
            // Re-installing must not wrap the shim around itself, so the
            // recorded delegate is carried over rather than re-read.
            delegate = existing
        case .notInstalled(let existing):
            delegate = selfReferenceGuard(existing)
        case .modifiedExternally(let current):
            delegate = selfReferenceGuard(current)
        }

        try backupSettings()
        try writeShim(delegate: delegate)
        try setCommand(paths.shimScript.path)
    }

    // MARK: - Uninstall

    public func uninstall() throws {
        let delegate = installedDelegate()
        try setCommand(delegate)
        try? FileManager.default.removeItem(at: paths.shimScript)
        try? FileManager.default.removeItem(at: paths.shimDelegateFile)
    }

    /// A delegate pointing at the shim itself would make it invoke itself
    /// forever, which would hang the statusline rather than merely break it.
    private func selfReferenceGuard(_ command: String?) -> String? {
        command == paths.shimScript.path ? nil : command
    }

    // MARK: - Shim script

    private func writeShim(delegate: String?) throws {
        guard
            let url = Bundle.module.url(forResource: "statusline-shim", withExtension: "sh"),
            let template = try? String(contentsOf: url, encoding: .utf8)
        else { throw ShimInstallError.templateMissing }

        let script = template
            .replacingOccurrences(of: "__STATE_FILE__", with: paths.claudeRawState.path)
            .replacingOccurrences(of: "__DELEGATE_FILE__", with: paths.shimDelegateFile.path)

        try FileManager.default.createDirectory(
            at: paths.claudeDirectory, withIntermediateDirectories: true
        )
        try Data(script.utf8).write(to: paths.shimScript)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: paths.shimScript.path
        )

        // Written as data, never interpolated into the script.
        if let delegate, !delegate.isEmpty {
            try Data(delegate.utf8).write(to: paths.shimDelegateFile)
        } else {
            try? FileManager.default.removeItem(at: paths.shimDelegateFile)
        }
    }

    /// Recovers the delegate from the sidecar file, so the app holds no
    /// separate state that could drift from what the shim will actually run.
    private func installedDelegate() -> String? {
        guard let value = try? String(contentsOf: paths.shimDelegateFile, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    // MARK: - settings.json

    private func settingsObject() -> [String: Any] {
        guard
            let data = try? Data(contentsOf: paths.claudeSettings),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private func currentCommand() -> String? {
        (settingsObject()["statusLine"] as? [String: Any])?["command"] as? String
    }

    private func backupSettings() throws {
        guard FileManager.default.fileExists(atPath: paths.claudeSettings.path) else { return }
        // Only the pre-install state is worth keeping; never overwrite an
        // existing backup with an already-shimmed settings file.
        guard !FileManager.default.fileExists(atPath: paths.claudeSettingsBackup.path) else { return }
        try FileManager.default.copyItem(at: paths.claudeSettings, to: paths.claudeSettingsBackup)
    }

    private func setCommand(_ command: String?) throws {
        var object = settingsObject()
        if let command {
            object["statusLine"] = ["command": command, "type": "command"]
        } else {
            object.removeValue(forKey: "statusLine")
        }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: paths.claudeDirectory, withIntermediateDirectories: true
        )
        try data.write(to: paths.claudeSettings)
    }
}
