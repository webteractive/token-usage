import Foundation

/// Decodes `zetty accounts --json`.
///
/// zetty is the authority on which account directories belong to which agent —
/// `~/.zetty/accounts/` mixes Claude and Codex logins, and reimplementing that
/// classification means guessing at a contract that can drift.
public enum ZettyAccountsParser {

    private struct Output: Decodable {
        struct Entry: Decodable {
            let agent: String
            let directory: String
            let id: String
            let name: String?
            let email: String?
            let orgName: String?
        }
        let accounts: [Entry]
        let defaultDirectory: String
    }

    public static func parse(_ data: Data, home: URL) throws -> [ClaudeAccount] {
        let output = try JSONDecoder().decode(Output.self, from: data)

        // The default login is reported separately and carries no identity here;
        // it is resolved from ~/.claude.json by the locator.
        let fallback = ClaudeAccount(
            id: ClaudeAccount.defaultID,
            directory: expand(output.defaultDirectory, home: home)
        )

        let named = output.accounts
            .filter { $0.agent == "claude" }
            .map { entry in
                ClaudeAccount(
                    id: entry.id,
                    directory: expand(entry.directory, home: home),
                    displayName: entry.name,
                    email: entry.email,
                    organizationName: entry.orgName
                )
            }
            .sorted { $0.id < $1.id }

        return [fallback] + named
    }

    /// zetty prints paths with `~` rather than expanded, and the home is
    /// injected so this is testable against a fixture.
    private static func expand(_ path: String, home: URL) -> URL {
        guard path.hasPrefix("~/") else { return URL(fileURLWithPath: path) }
        return home.appendingPathComponent(String(path.dropFirst(2)))
    }
}
