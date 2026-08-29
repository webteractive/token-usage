import XCTest
@testable import TokenUsageCore

final class UpdateAssetsTests: XCTestCase {
    private func asset(_ name: String) -> ReleaseAsset {
        ReleaseAsset(name: name, downloadURL: URL(string: "https://example.com/\(name)")!)
    }

    func testSelectsDMGAndChecksum() {
        let assets = [
            asset("notes.txt"),
            asset("TokenUsage-0.1.1.dmg"),
            asset("TokenUsage-0.1.1.dmg.sha256"),
        ]
        let picked = UpdateAssets.select(from: assets)
        XCTAssertEqual(picked.dmg?.lastPathComponent, "TokenUsage-0.1.1.dmg")
        XCTAssertEqual(picked.checksum?.lastPathComponent, "TokenUsage-0.1.1.dmg.sha256")
    }

    func testChecksumIsNotMistakenForDMG() {
        let picked = UpdateAssets.select(from: [asset("TokenUsage-0.1.1.dmg.sha256")])
        XCTAssertNil(picked.dmg)
        XCTAssertEqual(picked.checksum?.lastPathComponent, "TokenUsage-0.1.1.dmg.sha256")
    }

    func testMissingAssets() {
        let picked = UpdateAssets.select(from: [asset("readme.md")])
        XCTAssertNil(picked.dmg)
        XCTAssertNil(picked.checksum)
    }
}
