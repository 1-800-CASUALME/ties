import Foundation

/// Writes the first draft of a message to one person, in the user's own register (§7.4).
///
/// Nothing is sent: the draft comes back as text for the detail view to hand to Messages,
/// WhatsApp or Mail. `registerSample` is the user's own recent messages to that person, and
/// whether it may be passed at all is the caller's decision (§7.5: on-device, or the "let cloud
/// AI see local signals" switch is on) — this type sends whatever it is given.
public struct MessageDrafter: Sendable {
    /// The cap from §7.4. The schema asks for it too, but a word limit is not something a
    /// model reliably counts, so the draft is cut here as well.
    static let maxWords = 60

    private let provider: any AIProvider

    public init(provider: any AIProvider) {
        self.provider = provider
    }

    /// A message of at most 60 words saying what the user needs from this person.
    public func draft(need: String, person: Person, facts: ProfileFacts?, registerSample: [String]) async throws -> String {
        let data = try await provider.complete(
            system: AIPrompts.draftSystem,
            user: AIPrompts.draft(need: need, person: person, facts: facts, registerSample: registerSample),
            schemaJSON: AISchemas.draft,
            schemaName: AISchemas.draftName
        )
        return Self.tidied(try AISchemas.decode(RawDraft.self, from: data).message ?? "")
    }

    /// The draft as it goes into a message field: no wrapping quotes (models like to quote the
    /// message they were asked to write) and no more than 60 words.
    static func tidied(_ message: String) -> String {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first, let last = text.last, text.count >= 2, Self.quotePairs[first] == last {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > Self.maxWords else { return text }
        return words.prefix(Self.maxWords).joined(separator: " ")
    }

    /// Opening quote to its matching closing quote. Only a *matched* pair is stripped, so a
    /// message that happens to start and end with different quotes is left alone.
    private static let quotePairs: [Character: Character] = [
        "\"": "\"", "'": "'", "“": "”", "‘": "’", "«": "»",
    ]

    private struct RawDraft: Decodable {
        var message: String?
    }
}
