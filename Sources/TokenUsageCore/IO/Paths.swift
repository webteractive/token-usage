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

    /// One verbatim statusline payload per Claude Code session, written by the
    /// shim and named after the session.
    public var claudeSessions: URL {
        stateDirectory.appendingPathComponent("claude-sessions", isDirectory: true)
    }
    /// The single capture every session used to overwrite. Nothing reads it
    /// now; it is named only so an upgrade can remove it.
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

    public var zettyAccounts: URL {
        home.appendingPathComponent(".zetty/accounts", isDirectory: true)
    }

    public var tinkerDirectory: URL {
        home.appendingPathComponent("Library/Application Support/Tinker", isDirectory: true)
    }
    /// Tinker starts Claude Code with this as its config directory, which makes
    /// it a login of its own with its own Keychain item.
    public var tinkerClaudeDirectory: URL {
        tinkerDirectory.appendingPathComponent("claude", isDirectory: true)
    }
    /// The quota snapshot Tinker's own statusline keeps.
    public var tinkerUsage: URL { tinkerDirectory.appendingPathComponent("usage.json") }

    /// The default login's `oauthAccount` lives *beside* `~/.claude`, not inside
    /// it — `~/.claude/.claude.json` does not exist. Non-default accounts keep
    /// theirs inside their own config directory.
    public var defaultClaudeConfigJSON: URL {
        home.appendingPathComponent(".claude.json")
    }
}
