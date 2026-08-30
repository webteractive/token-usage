import XCTest
@testable import TokenUsageCore

final class ClaudeUsageAPITests: XCTestCase {
    private actor ScriptedTransport {
        private var statuses: [Int]
        private var requests: [URLRequest] = []
        private let body: Data

        init(statuses: [Int], body: Data) {
            self.statuses = statuses
            self.body = body
        }

        func send(_ request: URLRequest) -> (Data, URLResponse) {
            requests.append(request)
            let status = statuses.isEmpty ? 200 : statuses.removeFirst()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (body, response)
        }

        var requestCount: Int { requests.count }

        var authorizationHeaders: [String?] {
            requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/claude-api-usage", withExtension: "json")
        )
        return try Data(contentsOf: url)
    }

    func testSuccessfulRequestsReuseCachedCredential() async throws {
        let source = CredentialDataSource([
            credentialBlob(token: "cached", now: now, expiresInHours: 1),
        ])
        let credentials = KeychainCredentials(readData: source.read)
        let transport = ScriptedTransport(statuses: [200, 200], body: try fixture())
        let api = ClaudeUsageAPI(credentials: credentials) {
            await transport.send($0)
        }

        _ = try await api.fetch(now: now)
        _ = try await api.fetch(now: now.addingTimeInterval(60))

        let requestCount = await transport.requestCount
        XCTAssertEqual(source.readCount, 1)
        XCTAssertEqual(requestCount, 2)
    }

    func testUnauthorizedForcesRefreshAndRetriesOnce() async throws {
        let source = CredentialDataSource([
            credentialBlob(token: "old", now: now, expiresInHours: 1),
            credentialBlob(token: "new", now: now, expiresInHours: 1),
        ])
        let credentials = KeychainCredentials(readData: source.read)
        let transport = ScriptedTransport(statuses: [401, 200], body: try fixture())
        let api = ClaudeUsageAPI(credentials: credentials) {
            await transport.send($0)
        }

        _ = try await api.fetch(now: now)

        let requestCount = await transport.requestCount
        let headers = await transport.authorizationHeaders
        XCTAssertEqual(source.readCount, 2)
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(headers, ["Bearer old", "Bearer new"])
    }

    func testSecondUnauthorizedStopsAfterSingleRetry() async throws {
        let source = CredentialDataSource([
            credentialBlob(token: "old", now: now, expiresInHours: 1),
            credentialBlob(token: "new", now: now, expiresInHours: 1),
        ])
        let credentials = KeychainCredentials(readData: source.read)
        let transport = ScriptedTransport(statuses: [401, 403], body: try fixture())
        let api = ClaudeUsageAPI(credentials: credentials) {
            await transport.send($0)
        }

        do {
            _ = try await api.fetch(now: now)
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? ClaudeUsageAPIError, .unauthorized)
        }

        let requestCount = await transport.requestCount
        XCTAssertEqual(source.readCount, 2)
        XCTAssertEqual(requestCount, 2)
    }

    func testOtherHTTPFailuresAreNotRetried() async throws {
        let source = CredentialDataSource([
            credentialBlob(token: "cached", now: now, expiresInHours: 1),
        ])
        let credentials = KeychainCredentials(readData: source.read)
        let transport = ScriptedTransport(statuses: [500], body: try fixture())
        let api = ClaudeUsageAPI(credentials: credentials) {
            await transport.send($0)
        }

        do {
            _ = try await api.fetch(now: now)
            XCTFail("Expected HTTP failure")
        } catch {
            XCTAssertEqual(error as? ClaudeUsageAPIError, .http(500))
        }

        let requestCount = await transport.requestCount
        XCTAssertEqual(source.readCount, 1)
        XCTAssertEqual(requestCount, 1)
    }
}
