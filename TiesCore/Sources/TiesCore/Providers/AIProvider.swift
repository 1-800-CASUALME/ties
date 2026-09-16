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

/// One AI backend that can turn web text into `ProfileFacts`.
///
/// Conformers implement a single model call (`extractChunk`); the chunking, the
/// context-window retry, and the merge across chunks are shared by every provider through
/// the default `extract` below.
public protocol AIProvider: Sendable {
    var spec: ProviderSpec { get }
    /// One model call: send `system`/`user` and return the facts the model produced.
    func extractChunk(system: String, user: String) async throws -> ProfileFacts
    /// A cheap round-trip that proves the provider is reachable and configured.
    func validate() async throws
}

extension AIProvider {
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
