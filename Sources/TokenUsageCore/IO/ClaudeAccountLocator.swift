import Foundation

/// Finds every Claude login on this machine.
///
/// Primary source is `zetty accounts --json`, because zetty owns the mapping
/// from account directory to agent — `~/.zetty/accounts/` holds Codex logins
/// too. The filesystem fallback keeps the app working when zetty is not
/// installed, at the cost of missing an account nobody has signed into yet,
/// which has nothing to report anyway.
///
/// Discovery is not free (a ~28ms subprocess), so callers run it at launch and
/// when the accounts directory changes — never per refresh.
public struct ClaudeAccountLocator: Sendable {

    /// Searched in order. A GUI app does not inherit the shell's PATH, so the
    /// binary has to be located explicitly rather than by name.
    static let searchPaths = [
        "\(NSHomeDirectory())/.local/bin/zetty",
        "/opt/homebrew/bin/zetty",
        "/usr/local/bin/zetty",
    ]

    private let paths: Paths
    private let runZetty: @Sendable () -> Data?

    public init(paths: Paths = .live) {
        self.paths = paths
        self.runZetty = { Self.runListing() }
    }

    init(paths: Paths, runZetty: @escaping @Sendable () -> Data?) {
        self.paths = paths
        self.runZetty = runZetty
    }

    public static func locateBinary() -> String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A cheap signature of the accounts directory: the names it contains.
    ///
    /// `discover()` spawns a ~28ms subprocess, which is not something a menu bar
    /// app should do every minute for an answer that almost never changes.
    /// Callers compare this on each tick and rediscover only when it moves.
    public func fingerprint() -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(
            atPath: paths.zettyAccounts.path
        )) ?? []
        return Set(entries)
    }

    /// Always returns at least the default account, so the app never renders an
    /// empty Claude section on a machine that simply has no zetty.
    public func discover() -> [ClaudeAccount] {
        let discovered = fromZetty() ?? fromFilesystem()
        return discovered.map(withIdentity)
    }

    // MARK: - Sources

    private func fromZetty() -> [ClaudeAccount]? {
        guard let data = runZetty() else { return nil }
        return try? ZettyAccountsParser.parse(data, home: paths.home)
    }

    private func fromFilesystem() -> [ClaudeAccount] {
        let fallback = ClaudeAccount(id: ClaudeAccount.defaultID, directory: paths.claudeDirectory)

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: paths.zettyAccounts,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        let named = entries
            .filter { url in
                // A Claude account has a .claude.json; a Codex one has
                // config.toml instead. Without zetty this is the only signal.
                FileManager.default.fileExists(
                    atPath: url.appendingPathComponent(".claude.json").path
                )
            }
            .map { ClaudeAccount(id: $0.lastPathComponent, directory: $0) }
            .sorted { $0.id < $1.id }

        return [fallback] + named
    }

    // MARK: - Identity

    private func withIdentity(_ account: ClaudeAccount) -> ClaudeAccount {
        // zetty already reports identity for the accounts it lists; only fill in
        // what is missing, which is always the default account and any account
        // discovered by the fallback scan.
        guard account.displayName == nil else { return account }
        guard let identity = readIdentity(for: account) else { return account }

        return ClaudeAccount(
            id: account.id,
            directory: account.directory,
            displayName: identity.displayName,
            email: identity.emailAddress,
            organizationName: identity.organizationName
        )
    }

    private struct Identity: Decodable {
        let displayName: String?
        let emailAddress: String?
        let organizationName: String?
    }

    private func readIdentity(for account: ClaudeAccount) -> Identity? {
        struct Config: Decodable { let oauthAccount: Identity? }

        let url = account.isDefault
            ? paths.defaultClaudeConfigJSON
            : account.directory.appendingPathComponent(".claude.json")

        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data).oauthAccount
    }

    // MARK: - Subprocess

    /// A listing that never returns must not become an app that never returns.
    /// Reading to EOF blocks until the child exits, so a wedged zetty would
    /// otherwise hang the caller forever; the sibling Codex client sets a
    /// deadline for the same reason.
    static let listingTimeout: TimeInterval = 5

    private static func runListing() -> Data? {
        guard let binary = locateBinary() else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["accounts", "--json"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do { try process.run() } catch { return nil }

        // Terminating the child closes the pipe, which is what releases the
        // blocking read below — a timer around the read alone would not.
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + listingTimeout, execute: watchdog)

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        // A terminated child reports a non-zero status, so the timeout falls
        // through to the filesystem fallback rather than to a partial listing.
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }
}
