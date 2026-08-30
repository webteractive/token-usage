import Foundation

final class CredentialDataSource: @unchecked Sendable {
    private let lock = NSLock()
    private let blobs: [Data]
    private var reads = 0

    init(_ blobs: [Data]) {
        self.blobs = blobs
    }

    func read() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let blob = blobs[min(reads, blobs.count - 1)]
        reads += 1
        return blob
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }
}

func credentialBlob(token: String, now: Date, expiresInHours: Double?) -> Data {
    let expiry = expiresInHours.map { (now.timeIntervalSince1970 + $0 * 3600) * 1000 }
    let oauth: [String: Any] = expiry.map {
        ["accessToken": token, "expiresAt": $0]
    } ?? ["accessToken": token]
    return try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
}
