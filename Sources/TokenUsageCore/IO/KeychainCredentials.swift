import Foundation

public enum CredentialError: Error, Equatable {
    case notFound
    case malformed
    /// The access token is past its expiry. Claude Code refreshes it as you
    /// work, so the fix is to use Claude Code, not for this app to intervene.
    case expired
}

/// Reads Claude Code's OAuth access token from the login Keychain.
///
/// Read-only by design. The token is short-lived (hours) and Claude Code
/// refreshes it during normal use; this app never refreshes it and never writes
/// to the Keychain, because doing so would race Claude Code for the same item.
/// The token is cached in memory until expiry and never cached to disk.
public actor KeychainCredentials {
    public let service: String

    public init(service: String = "Claude Code-credentials") {
        self.service = service
        self.readData = { try Self.readKeychainData(service: service) }
    }

    init(
        service: String = "Claude Code-credentials",
        readData: @escaping @Sendable () throws -> Data
    ) {
        self.service = service
        self.readData = readData
    }

    public func accessToken(now: Date = .now, forceRefresh: Bool = false) throws -> String {
        if !forceRefresh, let cached, cached.isValid(at: now) {
            return cached.accessToken
        }

        let credential = try Self.credential(from: readData(), now: now)
        cached = credential
        return credential.accessToken
    }

    private struct Credential: Sendable {
        let accessToken: String
        let expiresAt: Date?

        func isValid(at date: Date) -> Bool {
            expiresAt.map { date < $0 } ?? true
        }
    }

    private let readData: @Sendable () throws -> Data
    private var cached: Credential?

    /// `security` normally answers at once. If it ever shows an access dialog
    /// instead, a background refresh must give up rather than wait on a click.
    static let readTimeout: TimeInterval = 5

    /// Read through `/usr/bin/security` rather than `SecItemCopyMatching`.
    ///
    /// Claude Code writes this item with the `security` tool, so the item's
    /// access list already trusts it and the read never prompts. Reading it
    /// from this app directly asks the user to allow access, and because the
    /// builds are ad-hoc signed, every new build is a new app to the Keychain
    /// and asks again, even after "Always Allow".
    private static func readKeychainData(service: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { throw CredentialError.notFound }

        // Terminating the child closes the pipe, which is what releases the
        // blocking read below — a timer around the read alone would not.
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + readTimeout, execute: watchdog)

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        return try itemData(fromSecurityOutput: data, status: process.terminationStatus)
    }

    /// Split out so the exit-status handling is testable without a Keychain.
    /// `-w` prints the secret followed by a newline; any non-zero status —
    /// a missing item, a denied read, a timed-out one — means no credential.
    static func itemData(fromSecurityOutput output: Data, status: Int32) throws -> Data {
        guard status == 0 else { throw CredentialError.notFound }
        var data = output
        while data.last == UInt8(ascii: "\n") { data.removeLast() }
        guard !data.isEmpty else { throw CredentialError.notFound }
        return data
    }

    /// Split out so the JSON handling is testable without a Keychain.
    static func token(from data: Data, now: Date) throws -> String {
        try credential(from: data, now: now).accessToken
    }

    private static func credential(from data: Data, now: Date) throws -> Credential {
        struct Blob: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                /// Milliseconds since epoch.
                let expiresAt: Double?
            }
            let claudeAiOauth: OAuth?
        }

        guard let oauth = try? JSONDecoder().decode(Blob.self, from: data).claudeAiOauth,
              !oauth.accessToken.isEmpty
        else { throw CredentialError.malformed }

        if let expiresAt = oauth.expiresAt,
           now.timeIntervalSince1970 >= expiresAt / 1000 {
            throw CredentialError.expired
        }
        return Credential(
            accessToken: oauth.accessToken,
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }
}
