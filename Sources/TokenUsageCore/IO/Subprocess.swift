import Foundation

/// The parts of running a child process that every caller here got wrong on its
/// own: a deadline that really fires, a child that is really gone afterwards,
/// and pipe descriptors that are closed rather than left for deallocation.
///
/// The last one matters beyond this app. macOS caps the kernel memory all pipes
/// share, and a menu bar app that leaks a few descriptors a minute for a week
/// uses it up — after which every new pipe on the machine gets a 512-byte
/// buffer and unrelated tools (Xcode, for one) deadlock.
enum Subprocess {

    /// How long a child gets to act on SIGTERM before it is sent SIGKILL.
    static let killGrace: TimeInterval = 2

    /// Runs a command to completion, returning its exit status and stdout.
    /// stderr is discarded. Returns nil if the command could not be launched;
    /// a command that outlives `timeout` is killed and reports a non-zero status.
    static func capture(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval,
        killGrace: TimeInterval = killGrace
    ) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        defer { close(output) }

        do { try process.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        let data = read(from: output.fileHandleForReading, until: deadline)
        // EOF on stdout usually means the child is exiting; let it, so a clean
        // exit is not turned into a SIGTERM status by a hasty signal.
        waitForExit(process, until: deadline)
        stop(process, killGrace: killGrace)

        return (process.terminationStatus, data)
    }

    /// Reads until EOF, the deadline, or `isComplete` accepts what has arrived.
    ///
    /// `FileHandle.availableData` and `readDataToEndOfFile` both block for as
    /// long as the child stays silent, so a deadline wrapped around them never
    /// fires. `poll` is what makes the deadline real.
    static func read(
        from handle: FileHandle,
        until deadline: Date,
        isComplete: (Data) -> Bool = { _ in false }
    ) -> Data {
        let descriptor = handle.fileDescriptor
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }

            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(remaining * 1000, 250).rounded(.up)))
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }

            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                break
            }
            if count == 0 { break }

            buffer.append(chunk, count: count)
            if isComplete(buffer) { break }
        }
        return buffer
    }

    /// Makes sure the child is gone and reaped: SIGTERM, a grace period, then
    /// SIGKILL. A child that is never waited on stays alive holding its pipes,
    /// and not every child honours SIGTERM.
    static func stop(_ process: Process, killGrace: TimeInterval = killGrace) {
        if process.isRunning {
            process.terminate()
            if !waitForExit(process, until: Date().addingTimeInterval(killGrace)) {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
    }

    @discardableResult
    static func waitForExit(_ process: Process, until deadline: Date) -> Bool {
        while process.isRunning {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    /// Closes both ends of a pipe. Foundation closes them when the handles are
    /// deallocated, but a `Process` can keep them alive far longer than the
    /// call that made them, so this is done explicitly on every path.
    static func close(_ pipe: Pipe) {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
}
