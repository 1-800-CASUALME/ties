import Foundation

/// Everything the model is told about one person: the address-book facts that identify them
/// and the pages the scan collected about them.
public struct ExtractionInput: Sendable {
    public var person: Person
    public var channels: [Channel]
    public var pages: [SourcePage]

    public init(person: Person, channels: [Channel] = [], pages: [SourcePage] = []) {
        self.person = person
        self.channels = channels
        self.pages = pages
    }
}

/// Why a provider could not answer. Transport-level failures (HTTP statuses, process exits)
/// are mapped into these few cases so the UI can react without knowing which provider ran.
public enum ProviderError: Error, Sendable, Equatable {
    /// The API key is missing, wrong, or lacks access (401/403).
    case unauthorized
    /// The provider answered, but not with facts we could use; carries the detail to show.
    case badResponse(String)
    /// A CLI provider's executable isn't on this Mac.
    case notInstalled(String)
    /// The provider exists but can't run right now (e.g. on-device model not ready).
    case unavailable(String)
    /// The prompt exceeded the model's context window; the caller can retry with less text.
    case contextTooLarge
}

extension ProviderError {
    /// Maps a transport failure onto the provider-level error the UI reacts to.
    static func from(_ error: HTTPError) -> ProviderError {
        switch error {
        case .status(let code, let body):
            if code == 401 || code == 403 { return .unauthorized }
            if code == 413 { return .contextTooLarge }
            let lowercased = body.lowercased()
            if code == 400, lowercased.contains("context") || lowercased.contains("token") {
                return .contextTooLarge
            }
            return .badResponse(body.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(body.prefix(300))")
        case .rateLimited(let retryAfter):
            return .badResponse("rate limited, retry in \(Int(retryAfter))s")
        case .transport(let message):
            return .badResponse(message)
        case .timeout:
            return .badResponse("the request timed out")
        }
    }
}

/// One AI backend.
///
/// Conformers implement a single model call, `complete`: send `system`/`user`, get back the
/// bytes of one JSON object matching `schemaJSON`. Everything above that — the extraction
/// prompt, the chunking, the context-window retry, the merge across chunks — is shared by
/// every provider through the defaults below, and every later AI feature (candidate judge,
/// smart lists, query expansion, fact check, drafts) asks for its own schema through the same
/// one call rather than growing a per-provider method of its own.
public protocol AIProvider: Sendable {
    var spec: ProviderSpec { get }
    /// One model call constrained to a schema: returns the raw bytes of the JSON object the
    /// model produced, for the caller to decode.
    ///
    /// `schemaJSON` is a JSON Schema document; `schemaName` names it for the providers that
    /// label their structured output (OpenAI's `json_schema.name`, Anthropic's tool name).
    /// Providers that cannot constrain the model ask for the schema in the prompt instead, so
    /// the bytes are what the model *said* it produced — decode defensively.
    func complete(system: String, user: String, schemaJSON: String, schemaName: String) async throws -> Data
    /// One model call for the extraction schema. Defaulted in terms of `complete`; a provider
    /// overrides it only when it has a better path for this one schema (Apple's on-device
    /// guided generation does).
    func extractChunk(system: String, user: String) async throws -> ProfileFacts
    /// A cheap round-trip that proves the provider is reachable and configured.
    func validate() async throws
}

extension AIProvider {
    /// The extraction call every provider shares: ask for the profile-facts schema, decode
    /// what comes back with the tolerant decoder.
    public func extractChunk(system: String, user: String) async throws -> ProfileFacts {
        let data = try await complete(
            system: system,
            user: user,
            schemaJSON: ProfileFactsSchema.json,
            schemaName: ProfileFactsSchema.name
        )
        return try ProfileFactsSchema.decode(data)
    }

    /// Runs the full extraction for one person: split the collected pages into
    /// context-sized chunks, make one model call per chunk, and merge the results.
    ///
    /// A chunk that still overflows the context window is halved and each half retried once
    /// — providers report sizes in tokens we can only estimate, so one correction step
    /// absorbs the estimate being off without risking an unbounded retry loop.
    public func extract(_ input: ExtractionInput) async throws -> ProfileFacts {
        let maxTokens = spec.tier == .onDevice ? 2_500 : 12_000
        var chunks = ExtractionPrompt.chunkedSources(input.pages, maxTokens: maxTokens)
        // No pages: still ask once, with only the address-book facts, so a provider that
        // knows the person from elsewhere can contribute something.
        if chunks.isEmpty { chunks = [""] }

        var parts: [ProfileFacts] = []
        for chunk in chunks {
            do {
                parts.append(try await extractChunk(chunk, of: input))
            } catch ProviderError.contextTooLarge {
                let halves = TextChunker.chunks(chunk, maxTokens: max(1, chunk.count / 8))
                guard halves.count > 1 else { throw ProviderError.contextTooLarge }
                for half in halves {
                    parts.append(try await extractChunk(half, of: input))
                }
            }
        }
        return FactsMerger.merge(parts)
    }

    public func validate() async throws {
        _ = try await extractChunk(system: ExtractionPrompt.system, user: ExtractionPrompt.validationSample)
    }

    private func extractChunk(_ chunk: String, of input: ExtractionInput) async throws -> ProfileFacts {
        try await extractChunk(
            system: ExtractionPrompt.system,
            user: ExtractionPrompt.user(input: input, chunk: chunk)
        )
    }
}

/// A schema string as the Foundation JSON value a request body can embed directly.
///
/// Providers take schemas as strings (a CLI flag, a file, a line of prompt all want text), but
/// the HTTP providers build their bodies with `JSONSerialization` and need the parsed value.
enum SchemaJSON {
    static func value(_ schemaJSON: String) throws -> Any {
        guard let value = try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8)),
              value is [String: Any]
        else {
            throw ProviderError.badResponse("not a JSON Schema object: \(schemaJSON.prefix(200))")
        }
        return value
    }
}
