import Foundation

public enum CodexAppServerError: Error, Equatable {
    case binaryNotFound
    case launchFailed(String)
    case noResponse
    case rpc(String)
}

/// Reads Codex quota by speaking JSON-RPC to `codex app-server` over stdio.
///
/// The obvious alternative — calling `https://chatgpt.com/api/codex/usage`
/// directly the way the Claude source does — does not work: that host sits
/// behind Cloudflare bot management and answers a plain client with
/// `403 cf-mitigated: challenge` regardless of a valid token. Getting past that
/// would mean impersonating a browser's TLS fingerprint, which is both
/// circumvention and brittle. Letting Codex's own binary make the request avoids
/// the problem entirely and means this app never handles Codex credentials.
public struct CodexAppServerClient: Sendable {

    /// Searched in order. A GUI app does not inherit the shell's PATH, so the
    /// binary has to be located explicitly rather than by name.
    static let searchPaths = [
        "\(NSHomeDirectory())/.local/bin/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "\(NSHomeDirectory())/.codex/bin/codex",
    ]

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 20) {
        self.timeout = timeout
    }

    public static func locateBinary() -> String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func fetch(now: Date = .now) throws -> ProviderUsage {
        guard let binary = Self.locateBinary() else { throw CodexAppServerError.binaryNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server"]

        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()

        do { try process.run() } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }

        // The protocol requires an initialize handshake before any other call.
        let requests = [
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"clientInfo":{"name":"token-usage","version":"1.0.0"}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"account/rateLimits/read","params":{}}"#,
        ].joined(separator: "\n") + "\n"

        input.fileHandleForWriting.write(Data(requests.utf8))

        // stdin stays open until the answer arrives: the server treats EOF as
        // "client is done" and exits, which is why closing it here returned
        // nothing at all.
        let data = try read(from: output, process: process)
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }

        guard let result = Self.result(id: 1, in: data) else {
            throw CodexAppServerError.noResponse
        }
        return try CodexAppServerParser.parse(result, observedAt: now)
    }

    /// Reads until the response to the rate-limits request arrives. The server
    /// interleaves unsolicited notifications, so waiting for "some output" is
    /// not enough — it has to be that specific id.
    private func read(from pipe: Pipe, process: Process) throws -> Data {
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty {
                guard process.isRunning else { break }
                // availableData returns immediately when the pipe is empty, so
                // without this the loop burns a core until the deadline.
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            buffer.append(chunk)
            if Self.result(id: 1, in: buffer) != nil { return buffer }
        }
        return buffer
    }

    /// Pulls one JSON-RPC response out of newline-delimited output.
    static func result(id: Int, in data: Data) -> Data? {
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["id"] as? Int == id
            else { continue }
            guard let result = object["result"] else { return nil }
            return try? JSONSerialization.data(withJSONObject: result)
        }
        return nil
    }
}
