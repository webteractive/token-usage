import XCTest
@testable import TokenUsageCore

/// Aggregation behaviour lives in QuotaWindowTests, which covers the generalised
/// window list. This file keeps only the provider identity.
final class ProviderUsageTests: XCTestCase {

    func testProviderLabels() {
        XCTAssertEqual(Provider.claude.shortLabel, "C")
        XCTAssertEqual(Provider.codex.shortLabel, "X")
        XCTAssertEqual(Provider.claude.displayName, "Claude")
        XCTAssertEqual(Provider.codex.displayName, "Codex")
    }
}
