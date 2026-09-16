import Foundation

/// The JSON Schema every provider asks the model to fill in, and a forgiving decoder for
/// what actually comes back.
///
/// The schema is written for OpenAI's strict structured-output mode, which is the strictest
/// consumer: every property must appear in `required` and no object may allow extra keys,
/// so the two optional strings are declared nullable instead of omitted. Providers that are
/// less strict accept the same document unchanged.
public enum ProfileFactsSchema {
    /// The schema as a compact JSON string (sorted keys, so it is byte-stable across runs
    /// and safe to paste into a prompt or pass to a CLI).
    public static let json: String = {
        guard let data = try? JSONSerialization.data(withJSONObject: schemaValue(), options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }()

    /// The same schema as a Foundation JSON object, for embedding in a request body that is
    /// itself serialized with `JSONSerialization`.
    public static func schemaValue() -> Any {
        let fact: [String: Any] = [
            "type": "object",
            "properties": [
                "text": ["type": "string"],
                "sources": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["text", "sources"],
            "additionalProperties": false,
        ]
        let facts: [String: Any] = ["type": "array", "items": fact]
        let nullableString: [String: Any] = ["type": ["string", "null"]]

        return [
            "type": "object",
            "properties": [
                "occupation": nullableString,
                "summary": nullableString,
                "companies": facts,
                "achievements": facts,
                "certificates": facts,
                "experience": facts,
                "canHelpWith": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["occupation", "summary", "companies", "achievements", "certificates", "experience", "canHelpWith"],
            "additionalProperties": false,
        ] as [String: Any]
    }

    /// Decodes model output into `ProfileFacts`, tolerating the ways models wrap JSON:
    /// ``` fences, prose before or after the object, missing arrays, and facts with no
    /// sources. Anything that still isn't a JSON object becomes `ProviderError.badResponse`.
    public static func decode(_ data: Data) throws -> ProfileFacts {
        var text = String(decoding: data, as: UTF8.self)
        if text.contains("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw ProviderError.badResponse("no JSON object in model output: \(text.prefix(200))")
        }

        do {
            let raw = try JSONDecoder().decode(RawFacts.self, from: Data(text[start...end].utf8))
            return raw.profileFacts
        } catch {
            throw ProviderError.badResponse("could not decode model output: \(error)")
        }
    }

    /// A mirror of `ProfileFacts` where every field is optional, so one missing array in the
    /// model's answer costs us that array rather than the whole extraction.
    private struct RawFacts: Decodable {
        var occupation: String?
        var summary: String?
        var companies: [RawFact]?
        var achievements: [RawFact]?
        var certificates: [RawFact]?
        var experience: [RawFact]?
        var canHelpWith: [String]?

        var profileFacts: ProfileFacts {
            ProfileFacts(
                occupation: ProfileFactsSchema.cleaned(occupation),
                summary: ProfileFactsSchema.cleaned(summary),
                companies: RawFact.facts(companies),
                achievements: RawFact.facts(achievements),
                certificates: RawFact.facts(certificates),
                experience: RawFact.facts(experience),
                canHelpWith: (canHelpWith ?? []).compactMap { ProfileFactsSchema.cleaned($0) }
            )
        }
    }

    private struct RawFact: Decodable {
        var text: String?
        var sources: [String]?

        static func facts(_ raw: [RawFact]?) -> [Fact] {
            (raw ?? []).compactMap { item in
                guard let text = ProfileFactsSchema.cleaned(item.text) else { return nil }
                return Fact(text: text, sources: (item.sources ?? []).compactMap { ProfileFactsSchema.cleaned($0) })
            }
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
