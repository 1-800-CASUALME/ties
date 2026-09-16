import Foundation

/// The signature every CLI provider runs its tool through. Injecting it keeps the argument
/// building and output parsing testable without a real binary on disk.
public typealias CLIRun = @Sendable (String, [String], String?) async throws -> CLIRunResult

/// Uses an already-signed-in Claude Code CLI, so a user who pays for Claude needs no API key.
///
/// The prompt goes in on stdin (it is far longer than a comfortable argv) and the CLI is
/// pinned to a single non-interactive turn with no tools and no session persistence: this is
/// one extraction, not a conversation, and it must not touch the user's session history.
public struct ClaudeCLIProvider: AIProvider {
    public let spec: ProviderSpec
    private let executable: String
    private let model: String
    private let runner: CLIRun

    public init(
        spec: ProviderSpec,
        executable: String,
        model: String = "haiku",
        runner: @escaping CLIRun = CLIRunner.defaultRun
    ) {
        self.spec = spec
        self.executable = executable
        self.model = model
        self.runner = runner
    }

    public func extractChunk(system: String, user: String) async throws -> ProfileFacts {
        let arguments = [
            "-p",
            "--output-format", "json",
            "--json-schema", ProfileFactsSchema.json,
            "--system-prompt", system,
            "--model", model,
            "--max-turns", "1",
            "--tools", "",
            "--no-session-persistence",
        ]
        let result = try await runner(executable, arguments, user)
        try CLIOutput.checkExit(result, tool: spec.name)

        guard let envelope = CLIOutput.envelope(result.stdout) else {
            // Not the JSON envelope we asked for; the answer may still be in there.
            return try ProfileFactsSchema.decode(Data(result.stdout.utf8))
        }
        // The CLI reports its own failures in a successful exit's envelope.
        if envelope["is_error"] as? Bool == true {
            throw ProviderError.badResponse(String(describing: envelope["result"] ?? result.stdout))
        }
        if let structured = envelope["structured_output"],
           let data = try? JSONSerialization.data(withJSONObject: structured) {
            return try ProfileFactsSchema.decode(data)
        }
        if let text = envelope["result"] as? String {
            return try ProfileFactsSchema.decode(Data(text.utf8))
        }
        throw ProviderError.badResponse("no result in \(spec.name) output: \(result.stdout.prefix(300))")
    }
}

/// Uses an already-signed-in Codex CLI.
///
/// Codex takes its schema from a file and writes its answer to another, so both are created
/// in a temporary directory that is removed once the call returns.
public struct CodexCLIProvider: AIProvider {
    public let spec: ProviderSpec
    private let executable: String
    private let runner: CLIRun

    public init(spec: ProviderSpec, executable: String, runner: @escaping CLIRun = CLIRunner.defaultRun) {
        self.spec = spec
        self.executable = executable
        self.runner = runner
    }

    public func extractChunk(system: String, user: String) async throws -> ProfileFacts {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ties-codex-\(UUID().uuidString)", isDirectory: true)
        let schemaURL = directory.appendingPathComponent("schema.json")
        let outputURL = directory.appendingPathComponent("out.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(ProfileFactsSchema.json.utf8).write(to: schemaURL)
        } catch {
            throw ProviderError.badResponse("could not stage \(spec.name) files: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let arguments = [
            "exec",
            "--output-schema", schemaURL.path,
            "-o", outputURL.path,
            "--sandbox", "read-only",
            "--skip-git-repo-check",
            "\(system)\n\n\(user)",
        ]
        let result = try await runner(executable, arguments, nil)
        try CLIOutput.checkExit(result, tool: spec.name)

        if let data = try? Data(contentsOf: outputURL), !data.isEmpty {
            return try ProfileFactsSchema.decode(data)
        }
        // Older builds print the answer instead of writing the file.
        guard !result.stdout.isEmpty else {
            throw ProviderError.badResponse("\(spec.name) wrote no output")
        }
        return try ProfileFactsSchema.decode(Data(result.stdout.utf8))
    }
}

/// Uses an already-signed-in Gemini CLI.
///
/// It has no schema flag, so the schema is asked for in the prompt and the answer is dug out
/// of the JSON envelope's `response` field, which is free-form model text.
public struct GeminiCLIProvider: AIProvider {
    public let spec: ProviderSpec
    private let executable: String
    private let runner: CLIRun

    public init(spec: ProviderSpec, executable: String, runner: @escaping CLIRun = CLIRunner.defaultRun) {
        self.spec = spec
        self.executable = executable
        self.runner = runner
    }

    public func extractChunk(system: String, user: String) async throws -> ProfileFacts {
        let prompt = """
            \(system)

            Return only JSON matching this schema:
            \(ProfileFactsSchema.json)

            \(user)
            """
        let result = try await runner(executable, ["-p", prompt, "--output-format", "json"], nil)
        try CLIOutput.checkExit(result, tool: spec.name)

        if let envelope = CLIOutput.envelope(result.stdout), let response = envelope["response"] as? String {
            return try ProfileFactsSchema.decode(Data(response.utf8))
        }
        return try ProfileFactsSchema.decode(Data(result.stdout.utf8))
    }
}

/// Shared handling of what a CLI leaves on stdout/stderr.
enum CLIOutput {
    /// Turns a non-zero exit into a `ProviderError`, preferring stderr for the message and
    /// falling back to stdout when the tool reported the failure there.
    static func checkExit(_ result: CLIRunResult, tool: String) throws {
        guard result.status != 0 else { return }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = stderr.isEmpty ? stdout : stderr
        throw ProviderError.badResponse(
            detail.isEmpty ? "\(tool) exited with status \(result.status)" : String(detail.prefix(300))
        )
    }

    /// The tool's stdout as a JSON object, or `nil` if it printed something else.
    static func envelope(_ stdout: String) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) else { return nil }
        return object as? [String: Any]
    }
}
