import Foundation
import TiesCore

#if canImport(FoundationModels)
import FoundationModels

/// Extraction on-device with Apple Intelligence: no API key, no network, nothing about the
/// user's contacts leaving the Mac. It is the first provider the app offers for that reason.
///
/// This lives in the app target rather than TiesCore because `FoundationModels` is weak-linked
/// here and only exists on macOS 26; `ProviderFactory` takes this provider as a closure so the
/// UI-free package never has to import the framework.
@available(macOS 26, *)
struct AppleFoundationProvider: AIProvider {
    let spec = ProviderCatalog.spec("apple")!

    /// Whether the on-device model is ready: Apple Intelligence can be unsupported, switched
    /// off, or still downloading its assets.
    static var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    /// Any schema, asked for in words. `FoundationModels` can only constrain generation
    /// against a compile-time `@Generable` type, so a schema chosen at runtime is quoted in
    /// the instructions and the object is dug back out of the model's text.
    func complete(system: String, user: String, schemaJSON: String, schemaName: String) async throws -> Data {
        let instructions = """
            \(system)

            Reply with one JSON object matching this schema and nothing else:
            \(schemaJSON)
            """
        let session = LanguageModelSession(instructions: instructions)
        do {
            // Greedy sampling: these calls should be reproducible, not creative.
            let response = try await session.respond(to: user, options: GenerationOptions(sampling: .greedy))
            guard let data = JSONExtractor.firstObject(in: response.content) else {
                throw ProviderError.badResponse("no JSON object in \(spec.name) output")
            }
            return data
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            // `AIProvider.extract` answers this by halving the chunk and retrying.
            throw ProviderError.contextTooLarge
        }
    }

    /// Extraction keeps the guided-generation path: `@Generable` constrains the model as it
    /// decodes, which is stricter — and on-device, cheaper — than asking for JSON in words.
    func extractChunk(system: String, user: String) async throws -> ProfileFacts {
        let session = LanguageModelSession(instructions: system)
        do {
            // Greedy sampling: extraction should be reproducible, not creative.
            let response = try await session.respond(
                to: user,
                generating: GenerableFacts.self,
                options: GenerationOptions(sampling: .greedy)
            )
            return response.content.toProfileFacts()
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            // `AIProvider.extract` answers this by halving the chunk and retrying.
            throw ProviderError.contextTooLarge
        }
    }

    func validate() async throws {
        _ = try await extractChunk(
            system: ExtractionPrompt.system,
            user: "Name: Test Person\nSources:\n[src:1] Test Person is a baker."
        )
    }
}

/// The on-device counterpart of `ProfileFacts`: the guided-generation schema the model fills
/// in, with the same fields and the per-field limits the shared prompt asks for.
@available(macOS 26, *)
@Generable(description: "Facts extracted about one specific person")
struct GenerableFacts {
    @Guide(description: "Current occupation or job title") var occupation: String?
    @Guide(description: "At most two sentences") var summary: String?
    @Guide(description: "Companies this person works or worked for", .maximumCount(6)) var companies: [GenerableFact]
    @Guide(description: "Notable achievements", .maximumCount(6)) var achievements: [GenerableFact]
    @Guide(description: "Certificates, degrees, or awards", .maximumCount(6)) var certificates: [GenerableFact]
    @Guide(description: "Roles held, most recent first", .maximumCount(8)) var experience: [GenerableFact]
    @Guide(description: "Short lowercase skill or domain tags", .maximumCount(8)) var canHelpWith: [String]

    func toProfileFacts() -> ProfileFacts {
        ProfileFacts(
            occupation: occupation,
            summary: summary,
            companies: companies.map(\.fact),
            achievements: achievements.map(\.fact),
            certificates: certificates.map(\.fact),
            experience: experience.map(\.fact),
            canHelpWith: canHelpWith
        )
    }
}

@available(macOS 26, *)
@Generable(description: "One fact with the sources it came from")
struct GenerableFact {
    @Guide(description: "The fact, in one short sentence") var text: String
    @Guide(description: "src ids cited from the input") var sources: [String]

    var fact: Fact { Fact(text: text, sources: sources) }
}
#endif
