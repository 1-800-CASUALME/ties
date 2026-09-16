import Foundation

/// A saved grouping of people — "Doctors", "Riyadh", "Founders" — proposed from profiles and
/// signals, then kept until the next regrouping replaces the whole set.
public struct SmartList: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// An SF Symbol name for the sidebar row.
    public var systemImage: String
    public var personIds: [String]
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        systemImage: String,
        personIds: [String] = [],
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.personIds = personIds
        self.createdAt = createdAt
    }
}
