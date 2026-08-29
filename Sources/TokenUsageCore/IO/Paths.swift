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
    /// Holds the delegated statusline command as plain data.
    ///
    /// Kept out of the shim script deliberately: interpolating an arbitrary
    /// command into shell source would break on quotes and expand `$(...)` at
    /// assignment time. Claude Code's own documented statusline example
    /// contains both, so this is a likely input, not a theoretical one.
    public var shimDelegateFile: URL {
        claudeDirectory.appendingPathComponent("tokenusage-shim-delegate")
    }

    public var codexSessions: URL {
        home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }
}
