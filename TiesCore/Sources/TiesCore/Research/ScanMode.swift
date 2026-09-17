import Foundation

/// How deeply the research digs into one person.
///
/// The wall clock is what this is about. Thorough runs four web searches, forty username
/// sites, and every page it can reach, which is around half a minute per person — fine for a
/// handful, a working day for a few hundred. Quick spends its searches on the one or two
/// queries that actually find people, checks the top username sites only, and reads the first
/// few pages, which brings a person in under ten seconds.
///
/// The numbers live here rather than at each call site so "what quick means" is one fact,
/// and the same fact the Scan screen's tooltip quotes.
public enum ScanMode: String, Codable, Sendable {
    case quick, thorough

    /// How many of the WhatsMyName professional sites `UsernameProbe` checks. The list is
    /// ordered by how likely a professional is to be on the site, so the first fifteen are
    /// where nearly every hit comes from.
    public var usernameSites: Int {
        switch self {
        case .quick: 15
        case .thorough: 40
        }
    }

    /// How many derived usernames each site is checked for. Every extra username multiplies
    /// the site list, so this is the expensive one: four usernames over forty sites is 160
    /// requests, two over fifteen is 30.
    ///
    /// `UsernameDeriver` already drops generic email local parts ("info", "admin", "contact"
    /// and the rest), so a shared company mailbox contributes no usernames to check in either
    /// mode; a `first.last@` address is a real signal and is kept.
    public var usernameCandidates: Int {
        switch self {
        case .quick: 2
        case .thorough: 4
        }
    }

    /// How many of a person's pages `PageFetchProbe` fetches, in the order they are held.
    public var pagesFetched: Int {
        switch self {
        case .quick: 3
        case .thorough: .max
        }
    }

    /// The wall clock one person gets, after which `Scanner` stops (spec §5).
    ///
    /// Quick hard-caps a person at twenty-five seconds: when it runs out no further probe is
    /// started, the one in flight is cancelled, and whatever was collected by then is scored.
    /// The cap is what keeps a bad web search — a challenge, a page that never finishes
    /// loading — from turning "under ten seconds a person" into minutes without anyone
    /// noticing. Thorough has no cap: it is the mode you pick when you want the whole answer
    /// however long it takes.
    public var perPersonBudget: Duration? {
        switch self {
        case .quick: .seconds(25)
        case .thorough: nil
        }
    }
}
