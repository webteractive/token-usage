import AppKit
import TokenUsageCore

enum UpdateInstallProgress: Sendable {
    case downloading(Double)
    case verifying
    case preparing
    case relaunching
}

enum UpdateInstallError: Error, CustomStringConvertible, Sendable {
    case notInstallable
    case download
    case checksumMismatch
    case mount
    case notWritable
    case helper

    var description: String {
        switch self {
        case .notInstallable:
            "This release has no downloadable app image."
        case .download:
            "The update download failed."
        case .checksumMismatch:
            "The downloaded update failed its checksum check."
        case .mount:
            "The update disk image couldn't be opened."
        case .notWritable:
            "Token Usage can't write to its own location. Move it to a writable folder and try again."
        case .helper:
            "The updater couldn't start the install helper."
        }
    }
}

/// Downloads, verifies, and stages an update before a detached helper swaps the
/// app bundle after the running process terminates.
final class UpdateInstaller: @unchecked Sendable {
    private(set) var isRunning = false

    func install(
        _ update: AvailableUpdate,
        progress: @escaping (UpdateInstallProgress) -> Void,
        completion: @escaping (Result<Void, UpdateInstallError>) -> Void
    ) {
        guard !isRunning else { return }
        guard let dmgURL = update.dmgURL, let checksumURL = update.checksumURL else {
            completion(.failure(.notInstallable))
            return
        }

        isRunning = true
        let reportProgress: (UpdateInstallProgress) -> Void = { value in
            DispatchQueue.main.async { progress(value) }
        }

        Task {
            let result = await Self.run(
                dmgURL: dmgURL,
                checksumURL: checksumURL,
                progress: reportProgress
            )
            DispatchQueue.main.async {
                self.isRunning = false
                completion(result)
                if case .success = result { NSApp.terminate(nil) }
            }
        }
    }

    private static func run(
        dmgURL: URL,
        checksumURL: URL,
        progress: @escaping (UpdateInstallProgress) -> Void
    ) async -> Result<Void, UpdateInstallError> {
        let fileManager = FileManager.default
        let pid = ProcessInfo.processInfo.processIdentifier
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("token-usage-self-update-\(pid)")
        try? fileManager.removeItem(at: workDirectory)

        do {
            try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        } catch {
            return .failure(.download)
        }

        let targetApp = Bundle.main.bundlePath
        let targetParent = (targetApp as NSString).deletingLastPathComponent
        guard fileManager.isWritableFile(atPath: targetParent) else {
            try? fileManager.removeItem(at: workDirectory)
            return .failure(.notWritable)
        }

        let dmgPath = workDirectory.appendingPathComponent("update.dmg")
        do {
            try await download(dmgURL, to: dmgPath) { progress(.downloading($0)) }
        } catch {
            try? fileManager.removeItem(at: workDirectory)
            return .failure(.download)
        }

        progress(.verifying)
        do {
            let published = try await fetchText(checksumURL)
            let bytes = try Data(contentsOf: dmgPath)
            guard UpdateChecksum.matches(data: bytes, publishedHex: published) else {
                try? fileManager.removeItem(at: workDirectory)
                return .failure(.checksumMismatch)
            }
        } catch {
            try? fileManager.removeItem(at: workDirectory)
            return .failure(.checksumMismatch)
        }

        progress(.preparing)
        let stagedApp = workDirectory.appendingPathComponent("TokenUsage.app")
        guard mountAndCopy(dmg: dmgPath, to: stagedApp) else {
            try? fileManager.removeItem(at: workDirectory)
            return .failure(.mount)
        }

        progress(.relaunching)
        let script = SelfUpdateScript.render(
            pid: pid,
            targetAppPath: targetApp,
            stagedAppPath: stagedApp.path,
            workDir: workDirectory.path
        )
        guard launchHelper(script: script) else {
            try? fileManager.removeItem(at: workDirectory)
            return .failure(.helper)
        }

        return .success(())
    }

    private static func download(
        _ url: URL,
        to destination: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let total = response.expectedContentLength
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= (1 << 16) {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 { progress(Double(received) / Double(total)) }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        progress(1)
    }

    private static func fetchText(_ url: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)
        return String(decoding: data, as: UTF8.self)
    }

    private static func mountAndCopy(dmg: URL, to stagedApp: URL) -> Bool {
        let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent(
            "token-usage-mnt-\(ProcessInfo.processInfo.processIdentifier)"
        )
        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        guard run(
            "/usr/bin/hdiutil",
            ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path]
        ) else {
            return false
        }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
            try? FileManager.default.removeItem(at: mountPoint)
        }

        let sourceApp = mountPoint.appendingPathComponent("TokenUsage.app")
        guard FileManager.default.fileExists(atPath: sourceApp.path),
              run("/usr/bin/ditto", [sourceApp.path, stagedApp.path])
        else {
            return false
        }
        return bundleIsComplete(at: stagedApp)
    }

    private static func bundleIsComplete(at app: URL) -> Bool {
        SelfUpdateScript.requiredBundlePaths.allSatisfy {
            FileManager.default.fileExists(atPath: app.appendingPathComponent($0).path)
        }
    }

    private static func launchHelper(script: String) -> Bool {
        let scriptURL = Paths.live.stateDirectory.appendingPathComponent("self-update.sh")
        do {
            try FileManager.default.createDirectory(
                at: scriptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
