import Foundation

/// The JSON Schemas the five AI services ask for, and the tolerant decode every one of them
/// runs on the answer.
///
/// They live together for the same reason the prompts do (`AIPrompts`): what the app asks a
/// model to produce is reviewable in one file rather than spread across five services. Each is
/// written for OpenAI's strict structured-output mode — the strictest consumer — so every
/// property appears in `required` and no object allows extra keys; every other provider takes
/// the same document unchanged, and the ones that cannot constrain a model at all get it
/// pasted into the prompt.
public enum AISchemas {
    // MARK: - Candidate judge

    public static let judgementName = "candidate_judgement"

    /// `reason` is capped in the schema *and* re-capped after decoding: it has to fit a chip.
    public static let judgement = """
        {"type":"object",\
        "properties":{\
        "candidateId":{"type":"string"},\
        "confidence":{"type":"number"},\
        "reason":{"type":"string","maxLength":90}},\
        "required":["candidateId","confidence","reason"],\
        "additionalProperties":false}
        """

    // MARK: - Smart lists

    public static let smartListsName = "smart_lists"

    /// The only SF Symbols a smart list may carry. A model free to invent a symbol name
    /// invents ones that don't exist, and an SF Symbol that doesn't exist is a blank sidebar
    /// row — so the list is offered to the model as a schema `enum` and checked again after
    /// decoding (`SmartListBuilder` falls back to `person.2`).
    public static let allowedSystemImages = [
        "stethoscope", "cross.case", "briefcase", "building.2", "hammer", "wrench.and.screwdriver",
        "cpu", "laptopcomputer", "chart.line.uptrend.xyaxis", "banknote", "scalemass", "graduationcap",
        "book", "paintbrush", "camera", "music.note", "airplane", "car", "house", "leaf",
        "fork.knife", "cart", "megaphone", "globe",
    ]

    public static let smartLists = """
        {"type":"object",\
        "properties":{\
        "lists":{"type":"array","items":{"type":"object",\
        "properties":{\
        "name":{"type":"string"},\
        "systemImage":{"type":"string","enum":[\(allowedSystemImages.map { "\"\($0)\"" }.joined(separator: ","))]},\
        "personIds":{"type":"array","items":{"type":"string"}}},\
        "required":["name","systemImage","personIds"],\
        "additionalProperties":false}}},\
        "required":["lists"],\
        "additionalProperties":false}
        """

    // MARK: - Query expansion

    public static let queryExpansionName = "query_expansion"

    public static let queryExpansion = """
        {"type":"object",\
        "properties":{"terms":{"type":"array","items":{"type":"string"}}},\
        "required":["terms"],\
        "additionalProperties":false}
        """

    // MARK: - Fact check

    public static let factCheckName = "fact_check"

    public static let factCheck = """
        {"type":"object",\
        "properties":{"supported":{"type":"array","items":{"type":"boolean"}}},\
        "required":["supported"],\
        "additionalProperties":false}
        """

    // MARK: - Message drafts

    public static let draftName = "message_draft"

    public static let draft = """
        {"type":"object",\
        "properties":{"message":{"type":"string"}},\
        "required":["message"],\
        "additionalProperties":false}
        """

    // MARK: - Decoding

    /// Decodes one of these schemas out of whatever a provider returned.
    ///
    /// Providers that can constrain the model hand back exactly the object; the CLIs and the
    /// on-device model hand back the object somewhere inside their own prose, which is what
    /// `JSONExtractor` is for. Anything that still isn't one JSON object — or doesn't decode —
    /// becomes `ProviderError.badResponse` with the text to show.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let text = String(decoding: data, as: UTF8.self)
        guard let object = JSONExtractor.firstObject(in: text) else {
            throw ProviderError.badResponse("no JSON object in model output: \(text.prefix(200))")
        }
        do {
            return try JSONDecoder().decode(type, from: object)
        } catch {
            throw ProviderError.badResponse("could not decode model output: \(error)")
        }
    }
}
