import CryptoKit
import Foundation

/// SHA-256 helpers for verifying a downloaded update.
public enum UpdateChecksum {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Matches a bare SHA-256 digest while tolerating case and whitespace.
    public static func matches(data: Data, publishedHex: String) -> Bool {
        let expected = publishedHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !expected.isEmpty else { return false }
        return sha256Hex(data) == expected
    }
}
