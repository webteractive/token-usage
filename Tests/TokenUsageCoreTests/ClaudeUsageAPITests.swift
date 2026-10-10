import XCTest
@testable import TokenUsageCore

final class ClaudeUsageAPITests: XCTestCase {
    private actor ScriptedTransport {
        private var statuses: [Int]
        private var requests: [URLRequest] = []
        private let body: Data
        private let headers: [String: String]?

        init(statuses: [Int], body: Data, headers: [String: String]? = nil) {
            self.statuses = statuses
            self.body = body
            self.headers = headers
        }

        func send(_ request: URLRequest) -> (Data, URLResponse) {
            requests.append(request)
            let status = statuses.isEmpty ? 200 : statuses.removeFirst()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
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

    private func rateLimitError(retryAfter: String?) async throws -> ClaudeUsageAPIError? {
        let source = CredentialDataSource([
            credentialBlob(token: "cached", now: now, expiresInHours: 1),
        ])
        let transport = ScriptedTransport(
            statuses: [429],
            body: Data(),
            headers: retryAfter.map { ["Retry-After": $0] }
        )
        let api = ClaudeUsageAPI(credentials: KeychainCredentials(readData: source.read)) {
            await transport.send($0)
        }

        do {
            _ = try await api.fetch(now: now)
            return nil
        } catch {
            let requestCount = await transport.requestCount
            XCTAssertEqual(requestCount, 1, "a refusal must not be retried on the spot")
            return error as? ClaudeUsageAPIError
        }
    }

    func testRateLimitCarriesTheServersHint() async throws {
        let error = try await rateLimitError(retryAfter: "600")
        XCTAssertEqual(error, .rateLimited(retryAfter: 600))
    }

    /// The endpoint answers `retry-after: 0` while it goes on refusing, which
    /// is no hint at all.
    func testRateLimitDiscardsAZeroHint() async throws {
        let zero = try await rateLimitError(retryAfter: "0")
        let absent = try await rateLimitError(retryAfter: nil)

        XCTAssertEqual(zero, .rateLimited(retryAfter: nil))
        XCTAssertEqual(absent, .rateLimited(retryAfter: nil))
    }
}
