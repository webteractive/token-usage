import XCTest
@testable import TokenUsageCore

final class SelfUpdateScriptTests: XCTestCase {
    private func render(
        pid: Int32 = 4242,
        target: String = "/Applications/TokenUsage.app",
        staged: String = "/tmp/token work/TokenUsage.app",
        workDir: String = "/tmp/token work"
    ) -> String {
        SelfUpdateScript.render(
            pid: pid,
            targetAppPath: target,
            stagedAppPath: staged,
            workDir: workDir
        )
    }

    func testRendersQuotedPathsAndPID() {
        let script = render()
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(script.contains("kill -0 4242"))
        XCTAssertTrue(script.contains("TARGET='/Applications/TokenUsage.app'"))
        XCTAssertTrue(script.contains("STAGED='/tmp/token work/TokenUsage.app'"))
        XCTAssertTrue(script.contains("WORKDIR='/tmp/token work'"))
        XCTAssertTrue(script.contains(#"ditto "$STAGED" "$TARGET""#))
        XCTAssertTrue(script.contains(#"xattr -dr com.apple.quarantine "$TARGET""#))
        XCTAssertTrue(script.contains(#"open "$TARGET""#))
        XCTAssertTrue(script.contains(#"rm -- "$0""#))
    }

    func testEscapesSingleQuotesInPaths() {
        let script = render(pid: 1, target: "/x/it's.app", staged: "/s/a.app", workDir: "/s")
        XCTAssertTrue(script.contains(#"'/x/it'\''s.app'"#))
    }

    func testMovesOldBundleAsideInsteadOfDeletingIt() {
        let script = render()
        XCTAssertTrue(script.contains(#"mv "$TARGET" "$BACKUP""#))
        XCTAssertFalse(script.contains(#"rm -rf "$TARGET""# + "\nditto"))
        XCTAssertTrue(script.contains(#"rm -rf "$BACKUP""#))
    }

    func testChecksBundleBeforeAndAfterCopy() {
        let script = render()
        for path in SelfUpdateScript.requiredBundlePaths {
            XCTAssertTrue(script.contains(path), "completeness check must cover \(path)")
        }
        XCTAssertTrue(script.contains(#"if ! complete "$STAGED""#))
        XCTAssertTrue(script.contains(#"complete "$TARGET""#))
    }

    func testRestoresOldBundleWhenCopyFails() {
        let script = render()
        XCTAssertTrue(script.contains(#"mv "$BACKUP" "$TARGET""#))
        XCTAssertTrue(script.contains(#"elif [ -d "$BACKUP" ]"#))
    }

    func testRequiredPathsMatchTokenUsageBundle() {
        XCTAssertEqual(SelfUpdateScript.requiredBundlePaths, [
            "Contents/MacOS/TokenUsage",
            "Contents/Info.plist",
            "Contents/Resources/TokenUsage_TokenUsageCore.bundle/Contents/Resources/statusline-shim.sh",
        ])
    }
}
