import XCTest
@testable import TokenUsageCore

final class SemVerTests: XCTestCase {
    func testParsesAndStripsVPrefix() {
        XCTAssertEqual(SemVer("v0.1.7"), SemVer("0.1.7"))
        XCTAssertNotNil(SemVer("1.2.3"))
        XCTAssertNil(SemVer("dev"))
        XCTAssertNil(SemVer(""))
        XCTAssertEqual(SemVer("1.2"), SemVer("1.2.0"))
    }

    func testOrdersVersions() {
        XCTAssertLessThan(SemVer("0.1.6")!, SemVer("0.1.7")!)
        XCTAssertGreaterThan(SemVer("0.2.0")!, SemVer("0.1.9")!)
        XCTAssertGreaterThan(SemVer("1.0.0")!, SemVer("0.9.9")!)
    }

    func testIsNewerRejectsEqualOlderAndInvalidVersions() {
        XCTAssertTrue(SemVer.isNewer(latest: "v0.1.7", than: "0.1.6"))
        XCTAssertFalse(SemVer.isNewer(latest: "0.1.6", than: "0.1.6"))
        XCTAssertFalse(SemVer.isNewer(latest: "0.1.5", than: "0.1.6"))
        XCTAssertFalse(SemVer.isNewer(latest: "0.1.7", than: "dev"))
        XCTAssertFalse(SemVer.isNewer(latest: "garbage", than: "0.1.6"))
    }
}
