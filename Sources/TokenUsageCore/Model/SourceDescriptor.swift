import Foundation

/// Identifies one row of the app: a provider, and for Claude, which login.
///
/// This replaces `Provider` as the key of every usage dictionary. `Provider`
/// survives unchanged — it answers *which vendor* — it simply stops being
/// specific enough to name a row now that one vendor can have several logins.
public struct SourceID: Hashable, Sendable {
    public let provider: Provider
    /// `nil` for a provider with a single login.
    public let account: String?

    public init(provider: Provider, account: String?) {
        self.provider = provider
        self.account = account
    }

    public static let codex = SourceID(provider: .codex, account: nil)

    public static func claude(_ accountID: String) -> SourceID {
        SourceID(provider: .claude, account: accountID)
    }
}

/// Everything the renderer and dropdown need to draw one row, resolved once at
/// discovery so nothing downstream recomputes labels or ordering.
public struct SourceDescriptor: Equatable, Sendable {
    public let id: SourceID
    public let displayName: String
    public let shortLabel: String
    /// `nil` for providers this app holds no credential for.
    public let keychainService: String?

    public init(id: SourceID, displayName: String, shortLabel: String, keychainService: String?) {
        self.id = id
        self.displayName = displayName
        self.shortLabel = shortLabel
        self.keychainService = keychainService
    }
}

public enum SourceCatalog {

    /// Builds the ordered render list: Claude accounts in the order given, then
    /// Codex. Never ordered by percentage — the menu bar must not reshuffle as
    /// numbers move.
    public static func descriptors(claudeAccounts: [ClaudeAccount]) -> [SourceDescriptor] {
        let labels = shortLabels(for: claudeAccounts.map(\.label))
        let single = claudeAccounts.count == 1

        let claude = zip(claudeAccounts, labels).map { account, label in
            SourceDescriptor(
                id: .claude(account.id),
                // With one login there is nothing to disambiguate, so the app
                // reads exactly as it did before accounts existed.
                displayName: single
                    ? Provider.claude.displayName
                    : "\(Provider.claude.displayName) · \(account.label)",
                shortLabel: single ? Provider.claude.shortLabel : label,
                keychainService: account.keychainService
            )
        }

        return claude + [
            SourceDescriptor(
                id: .codex,
                displayName: Provider.codex.displayName,
                shortLabel: Provider.codex.shortLabel,
                keychainService: nil
            )
        ]
    }

    /// The shortest uppercase prefix that tells these names apart. Uniqueness is
    /// resolved among Claude accounts only — Codex's fixed `X` does not compete,
    /// because the two never need telling apart from each other.
    static func shortLabels(for names: [String]) -> [String] {
        let upper = names.map { $0.uppercased() }
        let longest = upper.map(\.count).max() ?? 1

        for length in 1...max(longest, 1) {
            let candidates = upper.map { String($0.prefix(length)) }
            if Set(candidates).count == candidates.count { return candidates }
        }

        // Genuinely identical names: a position beats two identical letters.
        return upper.enumerated().map { "\($0.element.prefix(1))\($0.offset + 1)" }
    }
}
