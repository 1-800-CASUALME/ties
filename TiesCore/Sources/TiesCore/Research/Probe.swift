import Foundation

/// A research step that looks a person up somewhere on the web (or in a hashed-identity API)
/// and reports back whatever candidate identities/pages it found.
public protocol Probe: Sendable {
    /// A short, stable identifier for this probe (e.g. "gravatar", "github").
    var id: String { get }

    /// What the probe is looking at, for progress captions: "Searching \(displayName)…".
    /// Defaults to the id.
    var displayName: String { get }

    func run(_ input: ProbeInput, client: any HTTPClient) async throws -> [ProbeFinding]
}

public extension Probe {
    var displayName: String { id }
}
