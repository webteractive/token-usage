import Foundation

/// Every filesystem location the app touches, rooted at an injectable home so
/// the installer and store can be tested against a temporary directory.
public struct Paths: Sendable {
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    public static let live = Paths(home: FileManager.default.homeDirectoryForCurrentUser)

    public var stateDirectory: URL {
        home
            .appendingPathComponent("Library/Application Support/TokenUsage", isDirectory: true)
    }

    /// The verbatim statusline payload, written by the shim.
    public var claudeRawState: URL { stateDirectory.appendingPathComponent("claude-raw.json") }
    public var codexState: URL { stateDirectory.appendingPathComponent("codex.json") }

    public var claudeDirectory: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    public var claudeSettings: URL { claudeDirectory.appendingPathComponent("settings.json") }
    public var claudeSettingsBackup: URL {
        claudeDirectory.appendingPathComponent("settings.json.tokenusage-backup")
    }
    public var shimScript: URL { claudeDirectory.appendingPathComponent("tokenusage-shim.sh") }

    public var codexSessions: URL {
        home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }
}
