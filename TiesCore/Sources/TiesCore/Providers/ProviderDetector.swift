import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The outcome of checking whether a provider is available on this Mac.
/// The payload is a filesystem path, a base URL, or the literal `"Apple Intelligence"`,
/// depending on which `DetectRule` produced it.
public enum DetectResult: Sendable, Equatable {
    case available(String)
    case unavailable
}

/// Checks each `ProviderSpec`'s `DetectRule` against the current Mac: CLI executables on
/// `PATH`, app bundles under `/Applications`, local HTTP servers, and on-device Apple
/// Intelligence. Every dependency is injected so tests never touch the real filesystem,
/// shell, or network.
public struct ProviderDetector: Sendable {
    private let client: any HTTPClient
    private let fileExists: @Sendable (String) -> Bool
    private let which: @Sendable (String) async -> String?
    private let appleAvailable: @Sendable () -> Bool

    public init(
        client: any HTTPClient,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        which: @escaping @Sendable (String) async -> String? = ProviderDetector.loginShellWhich,
        appleAvailable: @escaping @Sendable () -> Bool = { false }
    ) {
        self.client = client
        self.fileExists = fileExists
        self.which = which
        self.appleAvailable = appleAvailable
    }

    /// Applies `spec.detect` (or reports `.unavailable` when the spec declares no rule,
    /// which for a cloud provider just means "needs an API key").
    public func detect(_ spec: ProviderSpec) async -> DetectResult {
        guard let rule = spec.detect else { return .unavailable }
        switch rule {
        case .appleIntelligence:
            return appleAvailable() ? .available("Apple Intelligence") : .unavailable
        case .appBundle(let name):
            return detectAppBundle(name)
        case .executable(let bin):
            if let path = await which(bin) { return .available(path) }
            return .unavailable
        case .http(let urlString):
            return await detectHTTP(urlString, baseURL: spec.defaultBaseURL)
        }
    }

    private func detectAppBundle(_ name: String) -> DetectResult {
        let systemPath = "/Applications/\(name)"
        if fileExists(systemPath) { return .available(systemPath) }
        let userPath = (NSHomeDirectory() as NSString).appendingPathComponent("Applications/\(name)")
        if fileExists(userPath) { return .available(userPath) }
        return .unavailable
    }

    private func detectHTTP(_ urlString: String, baseURL: String?) async -> DetectResult {
        guard let baseURL, let url = URL(string: urlString) else { return .unavailable }
        return await probeHTTP(url) ? .available(baseURL) : .unavailable
    }

    /// GETs `url` and reports success on any 2xx status, racing the request against a
    /// 1-second timeout since `HTTPClient.get` has none of its own. Any thrown error
    /// (including the injected client's) is treated as "not available", never propagated.
    ///
    /// The request bypasses every cache: this asks whether a local server is answering *now*,
    /// and the shared client's disk cache holds a 200 for a week, so a stopped Ollama would
    /// otherwise keep its "detected" dot lit for seven days across relaunches.
    private func probeHTTP(_ url: URL) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    let response = try await self.client.get(url, headers: [:], bypassCache: true)
                    return (200..<300).contains(response.status)
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    /// Resolves a CLI executable's absolute path the way an interactive terminal would:
    /// first via the user's login shell `PATH` (so shell-managed installs like nvm/asdf are
    /// found), then a handful of well-known install locations that aren't always on `PATH`
    /// for a GUI-launched process.
    public static func loginShellWhich(_ bin: String) async -> String? {
        if let path = await runShell("command -v \(bin)", timeout: .seconds(3)) {
            return path
        }
        let fallbacks = [
            "~/.claude/local/\(bin)",
            "~/.local/bin/\(bin)",
            "/opt/homebrew/bin/\(bin)",
            "/usr/local/bin/\(bin)",
        ]
        for path in fallbacks {
            let expanded = (path as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) { return expanded }
        }
        return nil
    }

    /// Runs `command` under `/bin/zsh -lc`, returning trimmed stdout (`nil` on empty output,
    /// a launch failure, or a timeout). Bounded by `timeout`: if the process hasn't finished
    /// by then, it is sent `SIGTERM` (then `SIGKILL` if it's still running shortly after), so
    /// this call never hangs past roughly `timeout` regardless of what the child process does.
    static func runShell(_ command: String, timeout: Duration) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await runProcess(command)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Runs `/bin/zsh -lc "<command>"` to completion and returns its trimmed stdout (`nil` if
    /// empty, or the process couldn't launch). If the surrounding task is cancelled while the
    /// process is still running (e.g. by `runShell`'s timeout racing it via `cancelAll()`),
    /// terminates the process so cancellation actually bounds the process's lifetime rather
    /// than just giving up on awaiting it.
    private static func runProcess(_ command: String) async -> String? {
        let state = ProcessState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                process.terminationHandler = { _ in
                    // Safe to drain now: the process has already exited, so both pipes'
                    // write ends are closed and these reads cannot block.
                    let outData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let text = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    state.resume(continuation, with: text.isEmpty ? nil : text)
                }

                state.setProcess(process)

                do {
                    try process.run()
                } catch {
                    state.resume(continuation, with: nil)
                }
            }
        } onCancel: {
            state.terminateIfRunning()
        }
    }

    /// Guards a `Process` and a `CheckedContinuation` that two independent callbacks — the
    /// process's `terminationHandler` and a task-cancellation `onCancel` — might both touch,
    /// so the continuation resumes exactly once and the process is only ever signaled while
    /// it's known to still be running.
    private final class ProcessState: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var resumed = false

        func setProcess(_ process: Process) {
            lock.lock(); self.process = process; lock.unlock()
        }

        func resume(_ continuation: CheckedContinuation<String?, Never>, with value: String?) {
            lock.lock()
            let alreadyResumed = resumed
            resumed = true
            lock.unlock()
            guard !alreadyResumed else { return }
            continuation.resume(returning: value)
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
