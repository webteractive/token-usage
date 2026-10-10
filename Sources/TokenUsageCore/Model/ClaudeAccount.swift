import CryptoKit
import Foundation

/// One Claude login on this machine: the default `~/.claude` one, a zetty
/// account under `~/.zetty/accounts/<id>`, or the one Tinker keeps for itself.
///
/// Identity fields are optional because an account directory can exist before
/// anyone has signed into it. Such an account is still listed and reports
/// "not signed in" — it exists, and silence about it would be the same failure
/// as printing 0% for "no data".
public struct ClaudeAccount: Equatable, Sendable {

    /// The tool a login belongs to, and so the one its sessions run under.
    public enum Owner: Equatable, Sendable {
        case claudeCode
        case zetty
        case tinker

        /// The heading its logins are listed under.
        public var sectionTitle: String {
            switch self {
            case .claudeCode: SourceCatalog.defaultSection
            case .zetty: "Zetty"
            case .tinker: "Tinker"
            }
        }
    }

    /// `"default"` for `~/.claude`, `"tinker"` for Tinker's login, otherwise the
    /// zetty account id.
    public let id: String
    public let directory: URL
    public let owner: Owner
    public let displayName: String?
    public let email: String?
    public let organizationName: String?

    public static let defaultID = "default"
    public static let tinkerID = "tinker"
    public static let defaultKeychainService = "Claude Code-credentials"

    public init(
        id: String,
        directory: URL,
        owner: Owner = .claudeCode,
        displayName: String? = nil,
        email: String? = nil,
        organizationName: String? = nil
    ) {
        self.id = id
        self.directory = directory
        self.owner = owner
        self.displayName = displayName
        self.email = email
        self.organizationName = organizationName
    }

    public var isDefault: Bool { id == Self.defaultID }

    /// What to call this account in the UI.
    public var label: String { displayName ?? id.capitalized }

    /// Claude Code stores each config directory's OAuth credential under its own
    /// generic-password service. The default directory keeps the bare name;
    /// every other one is suffixed with a digest of its absolute path, so an
    /// account is just the existing API pointed at a different Keychain item.
    public var keychainService: String {
        guard !isDefault else { return Self.defaultKeychainService }
        return "\(Self.defaultKeychainService)-\(Self.serviceSuffix(for: directory))"
    }

    /// `URL.path` yields no trailing slash, which matches what Claude Code
    /// hashes. Normalising here rather than at the call sites keeps a
    /// directory-flavoured URL from producing a different, silently wrong item.
    static func serviceSuffix(for directory: URL) -> String {
        let digest = SHA256.hash(data: Data(directory.path.utf8))
        // Four bytes are eight hex characters, which is the whole suffix.
        // %02x is already lowercase, so no further casing is needed.
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
