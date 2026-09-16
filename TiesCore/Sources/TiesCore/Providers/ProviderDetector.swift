import Foundation

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
    private func probeHTTP(_ url: URL) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    let response = try await self.client.get(url, headers: [:])
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
        if let path = await runCommandV(bin) {
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

    /// Runs `/bin/zsh -lc "command -v <bin>"`, racing it against a 3-second timeout.
    private static func runCommandV(_ bin: String) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    process.arguments = ["-lc", "command -v \(bin)"]
                    let outputPipe = Pipe()
                    process.standardOutput = outputPipe
                    process.standardError = Pipe()
                    process.terminationHandler = { _ in
                        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(returning: text.isEmpty ? nil : text)
                    }
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
