import XCTest
@testable import TokenUsageCore

final class SeverityTests: XCTestCase {

    func testDefaultThresholds() {
        XCTAssertEqual(Thresholds.default.warning, 75)
        XCTAssertEqual(Thresholds.default.critical, 90)
    }

    func testSeverityBands() {
        XCTAssertEqual(Severity.of(0), .normal)
        XCTAssertEqual(Severity.of(74.9), .normal)
        XCTAssertEqual(Severity.of(75), .warning)
        XCTAssertEqual(Severity.of(89.9), .warning)
        XCTAssertEqual(Severity.of(90), .critical)
        XCTAssertEqual(Severity.of(150), .critical)
    }

    func testCustomThresholds() {
        let t = Thresholds(warning: 50, critical: 60)
        XCTAssertEqual(Severity.of(55, t), .warning)
        XCTAssertEqual(Severity.of(60, t), .critical)
    }

    /// Colour alone fails for red-green colour deficiency and over arbitrary
    /// wallpapers, so every severity must carry a distinct shape.
    func testMarkersAreDistinct() {
        let markers = [Severity.normal, .warning, .critical].map(\.marker)
        XCTAssertEqual(markers, ["●", "▲", "■"])
        XCTAssertEqual(Set(markers).count, 3)
    }
}
