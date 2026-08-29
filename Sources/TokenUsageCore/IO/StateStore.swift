import Foundation

/// Reads and writes the small state files the collectors produce.
///
/// Writes go through a temporary sibling and an atomic rename, so a reader can
/// never observe a half-written file.
public struct StateStore: Sendable {
    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    public func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Sibling temp file keeps the rename within one filesystem, which is
        // what makes it atomic.
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try data.write(to: temp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    public func read(_ url: URL) throws -> (data: Data, modifiedAt: Date) {
        let data = try Data(contentsOf: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (data, attrs[.modificationDate] as? Date ?? Date())
    }

    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
