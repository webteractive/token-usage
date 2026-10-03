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
    private let killGrace: TimeInterval
    private let locate: @Sendable () -> String?

    public init(timeout: TimeInterval = 20) {
        self.init(timeout: timeout, killGrace: Subprocess.killGrace, locate: Self.locateBinary)
    }

    init(timeout: TimeInterval, killGrace: TimeInterval, locate: @escaping @Sendable () -> String?) {
        self.timeout = timeout
        self.killGrace = killGrace
        self.locate = locate
    }

    public static func locateBinary() -> String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func fetch(now: Date = .now) throws -> ProviderUsage {
        guard let binary = locate() else { throw CodexAppServerError.binaryNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server"]

        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        defer {
            Subprocess.close(input)
            Subprocess.close(output)
        }

        do { try process.run() } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }
        // Runs before the pipes are closed, on every path out of here. Without
        // it a server that never answers, or ignores SIGTERM, outlives the call.
        defer { Subprocess.stop(process, killGrace: killGrace) }

        // The protocol requires an initialize handshake before any other call.
        let requests = [
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"clientInfo":{"name":"token-usage","version":"1.0.0"}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"account/rateLimits/read","params":{}}"#,
        ].joined(separator: "\n") + "\n"

        // A server that died on launch leaves a pipe with no reader; that must
        // surface as an error here, not as SIGPIPE taking the app down.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try input.fileHandleForWriting.write(contentsOf: Data(requests.utf8)) } catch {
            throw CodexAppServerError.noResponse
        }

        // stdin stays open until the answer arrives: the server treats EOF as
        // "client is done" and exits, which is why closing it here returned
        // nothing at all.
        //
        // The server interleaves unsolicited notifications, so waiting for
        // "some output" is not enough — it has to be that specific id.
        let data = Subprocess.read(
            from: output.fileHandleForReading,
            until: Date().addingTimeInterval(timeout)
        ) { Self.result(id: 1, in: $0) != nil }

        guard let result = Self.result(id: 1, in: data) else {
            throw CodexAppServerError.noResponse
        }
        return try CodexAppServerParser.parse(result, observedAt: now)
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
