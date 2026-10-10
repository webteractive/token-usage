import Foundation

/// Reads the per-session statusline captures the shim writes.
///
/// Every session of every login lands in one directory, so the files are
/// decoded once and attributed per login afterwards. A session rewrites its
/// file only when the API has answered it again, so most reloads find nothing
/// new: decoded captures are kept by modification date and a file is reread
/// only when that date moves.
public final class ClaudeSessionCaptures {

    /// A weekly window is the longest thing a capture describes. A file older
    /// than this can only be describing windows that have since reset.
    public static let lifetime: TimeInterval = 8 * 24 * 60 * 60

    private struct Entry {
        let modifiedAt: Date
        /// `nil` for a file that could not be decoded, remembered so it is not
        /// reread on every reload either.
        let capture: ClaudeStatuslineParser.Capture?
    }

    private let directory: URL
    private var entries: [String: Entry] = [:]

    public init(directory: URL) {
        self.directory = directory
    }

    /// Picks up what changed on disk and deletes captures past their lifetime.
    public func reload(now: Date = .now) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        var current: [String: Entry] = [:]
        // The shim's half-written temporaries end in its process id, not .json.
        for file in files where file.pathExtension == "json" {
            guard let modifiedAt = (try? file.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate else { continue }

            guard now.timeIntervalSince(modifiedAt) <= Self.lifetime else {
                try? FileManager.default.removeItem(at: file)
                continue
            }

            let name = file.lastPathComponent
            if let known = entries[name], known.modifiedAt == modifiedAt {
                current[name] = known
            } else {
                let capture = (try? Data(contentsOf: file)).flatMap {
                    try? ClaudeStatuslineParser.capture($0, observedAt: modifiedAt)
                }
                current[name] = Entry(modifiedAt: modifiedAt, capture: capture)
            }
        }
        entries = current
    }

    /// The quota of one login, as its sessions last reported it.
    public func usage(for configDirectory: URL) -> ProviderUsage {
        let root = ClaudeStatuslineParser.root(of: configDirectory)
        return .merged(
            entries.values
                .compactMap(\.capture)
                .filter { $0.isInside(root) }
                .map(\.usage)
        )
    }
}
