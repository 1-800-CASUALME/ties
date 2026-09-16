import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What a finished child process left behind.
public struct CLIRunResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var status: Int32

    public init(stdout: String, stderr: String, status: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
    }
}

/// Runs a CLI tool to completion and collects its output.
///
/// The three things that make this different from a plain `Process` call: stdout and stderr
/// are drained concurrently (a model's answer easily exceeds the 64KB pipe buffer, and a
/// child blocked writing to a full pipe would never exit), the prompt is written to stdin
/// and the write end closed so the child sees EOF, and the whole thing is bounded by a
/// timeout that actually signals the process rather than just abandoning the await.
public enum CLIRunner {
    /// The runner every CLI provider uses unless a test injects its own.
    public static let defaultRun: CLIRun = {
        try await CLIRunner.run(executable: $0, arguments: $1, stdin: $2)
    }

    /// Runs `executable`, returning its output once it exits.
    /// - Throws: `ProviderError.notInstalled` if the executable can't be launched, or
    ///   `ProviderError.badResponse` if it is still running after `timeout` seconds.
    public static func run(
        executable: String,
        arguments: [String],
        stdin: String?,
        timeout: TimeInterval = 120
    ) async throws -> CLIRunResult {
        try await withThrowingTaskGroup(of: CLIRunResult?.self) { group in
            group.addTask {
                try await runProcess(executable: executable, arguments: arguments, stdin: stdin)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }

            let first = try await group.next() ?? nil
            // Cancelling either loser is what stops it: the timeout's sleep just ends, while
            // the process task's cancellation handler terminates the child.
            group.cancelAll()
            guard let first else {
                throw ProviderError.badResponse("\(executable) timed out after \(Int(timeout))s")
            }
            return first
        }
    }

    /// Environment for the child: the app's own environment with the usual CLI install
    /// locations prepended to `PATH`, since a GUI-launched app inherits a minimal `PATH`
    /// that rarely includes Homebrew or `~/.local/bin`.
    private static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let prefix = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
        let existing = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(prefix):\(existing)"
        return environment
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        stdin: String?
    ) async throws -> CLIRunResult {
        let state = ProcessState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLIRunResult, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment()

                let inputPipe = Pipe()
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardInput = inputPipe
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                // Drain both pipes on their own queues, so neither stream can fill up and
                // wedge the child while we wait for the other.
                let output = Output()
                let readers = DispatchGroup()
                readers.enter()
                DispatchQueue.global().async {
                    output.setStdout(outputPipe.fileHandleForReading.readDataToEndOfFile())
                    readers.leave()
                }
                readers.enter()
                DispatchQueue.global().async {
                    output.setStderr(errorPipe.fileHandleForReading.readDataToEndOfFile())
                    readers.leave()
                }

                process.terminationHandler = { finished in
                    let status = finished.terminationStatus
                    // Both reads hit EOF as the child exits; notify once they have, so no
                    // output is dropped and nothing blocks this callback's thread.
                    readers.notify(queue: .global()) {
                        state.resume(continuation, returning: CLIRunResult(
                            stdout: output.stdout,
                            stderr: output.stderr,
                            status: status
                        ))
                    }
                }

                state.setProcess(process)

                do {
                    try process.run()
                } catch {
                    // Nothing will close the pipes' write ends now, so close them here or the
                    // two reader queues block on EOF that never comes.
                    try? inputPipe.fileHandleForWriting.close()
                    try? outputPipe.fileHandleForWriting.close()
                    try? errorPipe.fileHandleForWriting.close()
                    state.resume(continuation, throwing: ProviderError.notInstalled(executable))
                    return
                }

                let writer = inputPipe.fileHandleForWriting
                if let stdin {
                    DispatchQueue.global().async {
                        writer.write(Data(stdin.utf8))
                        try? writer.close()
                    }
                } else {
                    // Close anyway: a child reading stdin needs EOF, not an open empty pipe.
                    try? writer.close()
                }
            }
        } onCancel: {
            state.terminateIfRunning()
        }
    }

    /// Collects the child's two output streams from the queues that read them.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data()
        private var errData = Data()

        func setStdout(_ data: Data) { lock.lock(); outData = data; lock.unlock() }
        func setStderr(_ data: Data) { lock.lock(); errData = data; lock.unlock() }

        var stdout: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: outData, as: UTF8.self)
        }

        var stderr: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: errData, as: UTF8.self)
        }
    }

    /// Guards the `Process` and the `CheckedContinuation` that the termination handler and a
    /// task-cancellation handler might both touch, so the continuation resumes exactly once
    /// and the process is only signaled while it is known to still be running.
    private final class ProcessState: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var resumed = false

        func setProcess(_ process: Process) {
            lock.lock(); self.process = process; lock.unlock()
        }

        func resume(_ continuation: CheckedContinuation<CLIRunResult, Error>, returning value: CLIRunResult) {
            guard claim() else { return }
            continuation.resume(returning: value)
        }

        func resume(_ continuation: CheckedContinuation<CLIRunResult, Error>, throwing error: Error) {
            guard claim() else { return }
            continuation.resume(throwing: error)
        }

        private func claim() -> Bool {
            lock.lock()
            let alreadyResumed = resumed
            resumed = true
            lock.unlock()
            return !alreadyResumed
        }

        func terminateIfRunning() {
            lock.lock()
            let process = process
            lock.unlock()
            guard let process, process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }
    }
}
