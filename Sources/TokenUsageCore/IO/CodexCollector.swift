import Foundation

/// Reads the current Codex quota from the newest rollout file.
///
/// Rollout files reach hundreds of megabytes, so only a tail is read — a 256 KB
/// tail measures ~18 ms against a corpus containing a 328 MB file. Quota is
/// account-wide, so the most recently modified file holds the current truth.
public struct CodexCollector: Sendable {
    public let paths: Paths
    public let tailBytes: Int

    /// Used when the first tail lands past the last reading. Bounded so a
    /// pathological file cannot pull the whole corpus into memory.
    private static let widenedTailBytes = 4 * 1024 * 1024

    public init(paths: Paths, tailBytes: Int = 256 * 1024) {
        self.paths = paths
        self.tailBytes = tailBytes
    }

    public func newestRollout() -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: paths.codexSessions,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: (url: URL, modified: Date)?
        for case let url as URL in walker {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else { continue }

            if modified > (newest?.modified ?? .distantPast) {
                newest = (url, modified)
            }
        }
        return newest?.url
    }

    public func collect() -> ProviderUsage? {
        guard let url = newestRollout() else { return nil }
        if let usage = read(url, bytes: tailBytes) { return usage }
        // Widen once: the first tail can begin after the last reading in a
        // session that kept writing non-usage events.
        guard tailBytes < Self.widenedTailBytes else { return nil }
        return read(url, bytes: Self.widenedTailBytes)
    }

    private func read(_ url: URL, bytes: Int) -> ProviderUsage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }

        return CodexRolloutParser.parseLatest(chunk: String(decoding: data, as: UTF8.self))
    }
}
