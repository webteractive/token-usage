import Foundation

/// Renders the detached POSIX-sh helper that replaces the app after it quits.
/// The old bundle stays available until the staged bundle has been copied and
/// checked, so a partial copy can be rolled back instead of bricking the app.
public enum SelfUpdateScript {
    /// The executable, processed Info.plist, and SwiftPM resource bundle are the
    /// files required to establish that this app was copied structurally.
    public static let requiredBundlePaths = [
        "Contents/MacOS/TokenUsage",
        "Contents/Info.plist",
        "Contents/Resources/TokenUsage_TokenUsageCore.bundle/Contents/Resources/statusline-shim.sh",
    ]

    public static func render(
        pid: Int32,
        targetAppPath: String,
        stagedAppPath: String,
        workDir: String
    ) -> String {
        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        let completenessCheck = requiredBundlePaths.enumerated().map { index, path in
            let test = index == 0 ? "-x" : "-f"
            return "[ \(test) \"$1/\(path)\" ]"
        }.joined(separator: " && ")

        return """
        #!/bin/sh
        # Token Usage self-update helper (generated). Waits for the app to quit,
        # swaps the bundle through a backup, relaunches, and self-deletes.
        TARGET=\(quote(targetAppPath))
        STAGED=\(quote(stagedAppPath))
        WORKDIR=\(quote(workDir))
        BACKUP="$TARGET.token-usage-previous"

        complete() {
            \(completenessCheck)
        }

        finish() {
            xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
            rm -rf "$WORKDIR"
            open "$TARGET"
            rm -- "$0"
        }

        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done

        if ! complete "$STAGED"; then
            finish
            exit 1
        fi

        rm -rf "$BACKUP"
        mv "$TARGET" "$BACKUP" 2>/dev/null
        if ditto "$STAGED" "$TARGET" && complete "$TARGET"; then
            rm -rf "$BACKUP"
        elif [ -d "$BACKUP" ]; then
            rm -rf "$TARGET"
            mv "$BACKUP" "$TARGET"
        fi
        finish
        """
    }
}
