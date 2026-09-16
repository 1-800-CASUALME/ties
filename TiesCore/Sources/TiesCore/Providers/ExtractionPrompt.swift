import Foundation

/// The prompt every provider sends: one fixed system instruction, plus a user message that
/// pairs the address-book facts (so the model can tell this person apart from namesakes)
/// with a chunk of the collected source text.
public enum ExtractionPrompt {
    public static let system = """
        You extract facts about one specific person from web text. \
        Output only JSON matching the schema. Never invent. Leave fields empty when unsure. \
        canHelpWith: up to 8 short lowercase tags of skills/domains this person could help someone with. \
        summary: at most two sentences. \
        Ignore text about other people with the same name unless the context clearly matches the known facts.
        """

    /// A one-line prompt used by `validate()`: enough to prove the provider answers with
    /// schema-shaped JSON, cheap enough to run whenever a key or CLI is configured.
    public static let validationSample = """
        Name: Test Person
        Sources:
        [src:1] Test Person is a baker.
        """

    /// The user message for one chunk: known facts first, then the source text.
    /// An empty chunk (no pages were collected) leaves the sources section out entirely.
    public static func user(input: ExtractionInput, chunk: String) -> String {
        var lines = ["Known facts from my address book:"]
        let name = input.person.displayName.trimmingCharacters(in: .whitespaces)
        lines.append("Name: \(name)")
        if let company = nonEmpty(input.person.organization) { lines.append("Company: \(company)") }
        if let title = nonEmpty(input.person.jobTitle) { lines.append("Title: \(title)") }
        let emails = input.channels.filter { $0.kind == .email }.map(\.value)
        if !emails.isEmpty { lines.append("Emails: \(emails.joined(separator: ", "))") }

        var prompt = lines.joined(separator: "\n")
        let sources = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sources.isEmpty { prompt += "\n\nSources:\n\(sources)" }
        return prompt
    }

    /// Renders the collected pages as source text and splits it into chunks of at most
    /// `maxTokens` tokens.
    ///
    /// Every line carries its own `[src:<id>] ` marker, so a chunk boundary can fall
    /// anywhere — mid-page, between pages — and the model can still cite the page each line
    /// came from. Pages are joined line-by-line rather than as indivisible blocks, so the
    /// chunker can pack several small pages together and split a large one.
    public static func chunkedSources(_ pages: [SourcePage], maxTokens: Int) -> [String] {
        let document = pages.flatMap { markedLines(for: $0, maxTokens: maxTokens) }.joined(separator: "\n")
        return TextChunker.chunks(document, maxTokens: maxTokens)
    }

    /// One page as `[src:<id>] `-prefixed lines: the "title — snippet" heading, then its body
    /// text. Each line is pre-split to fit inside a single chunk (marker included), so the
    /// chunker only ever splits *between* lines and never orphans text from its marker.
    /// A page with no text at all contributes no lines.
    private static func markedLines(for page: SourcePage, maxTokens: Int) -> [String] {
        let marker = "[src:\(page.id)] "
        // Reserve the marker's own tokens (~4 characters each, rounded up) out of the budget.
        let budget = max(1, maxTokens - (marker.count + 3) / 4)

        let heading = [nonEmpty(page.title), nonEmpty(page.snippet)].compactMap { $0 }.joined(separator: " — ")
        var lines = TextChunker.chunks(heading, maxTokens: budget)
        if let body = nonEmpty(page.bodyText) {
            for line in body.components(separatedBy: .newlines) {
                lines += TextChunker.chunks(line, maxTokens: budget)
            }
        }
        return lines.map { marker + $0 }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
