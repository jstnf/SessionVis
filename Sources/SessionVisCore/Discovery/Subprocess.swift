import Foundation

/// Runs a command through `/usr/bin/env` with stderr discarded. Reads stdout to the end before waiting for exit (a
/// pipe that fills would otherwise deadlock). After `timeout` the process is terminated, then killed once
/// `Constants.gitKillGrace` passes, and the read is abandoned even if a descendant still holds the pipe open.
/// nil when it could not be launched or timed out; a timed-out run never returns partial output.
enum Subprocess {
    struct Result {
        let status: Int32
        let output: Data
    }

    /// `Process` is not Sendable; the timeout closures only call its thread-safe `isRunning`, `terminate` and
    /// `processIdentifier`. The flags are guarded by a lock.
    private final class Handle: @unchecked Sendable {
        let process: Process
        private let lock = NSLock()
        private var timedOutFlag = false
        private var abandonedFlag = false
        init(_ process: Process) { self.process = process }

        var timedOut: Bool { lock.withLock { timedOutFlag } }
        var abandoned: Bool { lock.withLock { abandonedFlag } }

        func terminate() {
            lock.withLock { timedOutFlag = true }
            if process.isRunning { process.terminate() }
        }

        func kill() {
            lock.withLock { abandonedFlag = true }
            if process.isRunning { Foundation.kill(process.processIdentifier, SIGKILL) }
        }
    }

    static func run(_ args: [String], timeout: TimeInterval) -> Result? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let handle = Handle(p)
        let terminator = DispatchWorkItem { handle.terminate() }
        let killer = DispatchWorkItem { handle.kill() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: terminator)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout + Constants.gitKillGrace, execute: killer)
        let data = readToEnd(pipe.fileHandleForReading.fileDescriptor, abandon: { handle.abandoned })
        if !handle.abandoned { p.waitUntilExit() }
        terminator.cancel()
        killer.cancel()
        try? pipe.fileHandleForReading.close()
        if handle.timedOut || handle.abandoned { return nil }
        return Result(status: p.terminationStatus, output: data)
    }

    /// Reads until end of file, polling so the read can be given up on while a descendant keeps the pipe open.
    private static func readToEnd(_ fd: Int32, abandon: () -> Bool) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !abandon() {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(Constants.gitReadPollInterval * 1000))
            if ready < 0 { if errno == EINTR { continue } else { break } }
            if ready == 0 { continue }
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { data.append(buffer, count: n) }
            else if n == 0 || errno != EINTR { break }
        }
        return data
    }
}
