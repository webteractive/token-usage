import XCTest
@testable import TokenUsageCore

final class CodexAppServerClientTests: XCTestCase {

    /// The server interleaves unsolicited notifications with responses, so
    /// picking "the first line of output" would grab the wrong thing.
    func testExtractsTheRequestedIdNotTheFirstLine() throws {
        let stream = """
        {"id":0,"result":{"userAgent":"x"}}
        {"method":"remoteControl/status/changed","params":{"status":"disabled"}}
        {"id":1,"result":{"rateLimits":{"limitId":"codex"}}}
        """
        let result = try XCTUnwrap(CodexAppServerClient.result(id: 1, in: Data(stream.utf8)))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertNotNil(object["rateLimits"])
    }

    func testReturnsNilUntilTheResponseArrives() {
        let partial = #"{"id":0,"result":{}}"# + "\n" + #"{"method":"some/notification"}"#
        XCTAssertNil(CodexAppServerClient.result(id: 1, in: Data(partial.utf8)))
    }

    func testTolerablesTruncatedTrailingLine() throws {
        let stream = """
        {"id":1,"result":{"rateLimits":{"limitId":"codex"}}}
        {"id":2,"result":{"partial
        """
        XCTAssertNotNil(CodexAppServerClient.result(id: 1, in: Data(stream.utf8)))
    }

    /// A GUI app does not inherit the shell PATH, so the binary must be found by
    /// explicit path or not at all.
    func testSearchPathsAreAbsolute() {
        XCTAssertFalse(CodexAppServerClient.searchPaths.isEmpty)
        for path in CodexAppServerClient.searchPaths {
            XCTAssertTrue(path.hasPrefix("/"), "\(path) is not absolute")
        }
    }
}
