import Foundation

/// Groups the extracted network into a handful of named lists for the sidebar (§7.2).
///
/// The model sees one line per person — id, occupation, skills — and nothing else: no names,
/// no companies, no notes, no message history. That is enough to group by profession and keeps
/// the request small enough to send the whole network at once.
///
/// `build` returns the lists for the caller to show and to persist with
/// `Store.replaceSmartLists`; it doesn't write to the store itself, so a refresh that the
/// model fumbles can't wipe the lists already on screen.
public struct SmartListBuilder: Sendable {
    /// At most 8 lists reach the sidebar (§7.2), and a list of one person isn't a group.
    static let maxLists = 8
    static let minimumMembers = 2
    /// How many people are described to the model. Beyond this the most recently extracted
    /// ones are sampled: a freshly extracted person is the one the user is looking at.
    static let maxPeople = 300
    /// What a list gets when the model names a symbol outside the allowed set.
    static let fallbackSymbol = "person.2"
    static let allowedSymbols = Set(AISchemas.allowedSystemImages)

    private let store: Store
    private let provider: any AIProvider

    public init(store: Store, provider: any AIProvider) {
        self.store = store
        self.provider = provider
    }

    /// Proposes the smart lists. Returns `[]` — without calling the provider — when fewer than
    /// two people have anything to group by.
    ///
    /// Everything the model proposes is checked before it becomes a `SmartList`: unnamed lists
    /// and ids that aren't in the input are dropped, duplicates within a list collapse, lists
    /// left with fewer than two people go, an unknown SF Symbol falls back to `person.2`, and
    /// only the first 8 survivors are kept.
    public func build() async throws -> [SmartList] {
        let people = try input()
        guard people.count >= Self.minimumMembers else { return [] }

        let data = try await provider.complete(
            system: AIPrompts.smartListsSystem,
            user: AIPrompts.smartLists(people),
            schemaJSON: AISchemas.smartLists,
            schemaName: AISchemas.smartListsName
        )
        let proposed = try AISchemas.decode(RawLists.self, from: data)
        let known = Set(people.map(\.personId))

        var lists: [SmartList] = []
        for raw in proposed.lists ?? [] {
            guard lists.count < Self.maxLists else { break }
            let name = (raw.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            var seen = Set<String>()
            let personIds = (raw.personIds ?? []).filter { known.contains($0) && seen.insert($0).inserted }
            guard personIds.count >= Self.minimumMembers else { continue }

            let symbol = raw.systemImage ?? ""
            lists.append(SmartList(
                name: name,
                systemImage: Self.allowedSymbols.contains(symbol) ? symbol : Self.fallbackSymbol,
                personIds: personIds
            ))
        }
        return lists
    }

    /// The people worth grouping: everyone with an occupation or a skill, most recently
    /// extracted first, capped at `maxPeople`.
    ///
    /// Only `occupation` and `canHelpWith` are used, which is also why fact-checking doesn't
    /// change the input — neither is a `Fact`, so neither can be unsupported (§7.6).
    private func input() throws -> [(personId: String, occupation: String?, skills: [String])] {
        try store.profilesByPerson().values
            .filter { !$0.facts.canHelpWith.isEmpty || !($0.facts.occupation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                // Ids break extraction-time ties, so the sample (and the prompt) is stable.
                lhs.extractedAt == rhs.extractedAt ? lhs.personId < rhs.personId : lhs.extractedAt > rhs.extractedAt
            }
            .prefix(Self.maxPeople)
            .map { (personId: $0.personId, occupation: $0.facts.occupation, skills: $0.facts.canHelpWith) }
    }

    /// Every field optional: one malformed list costs us that list, not the whole regrouping.
    private struct RawLists: Decodable {
        var lists: [RawList]?

        struct RawList: Decodable {
            var name: String?
            var systemImage: String?
            var personIds: [String]?
        }
    }
}
