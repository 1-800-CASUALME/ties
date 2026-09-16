import Foundation

/// A snapshot of a `Scanner` run's progress, streamed to observers (e.g. the UI) as each
/// person finishes or the scanner starts waiting out a search-backend challenge.
public struct ScanProgress: Sendable, Equatable {
    /// Number of people finished so far. A person counts as finished whether their probes all
    /// succeeded, some failed, or the person-level scan itself failed.
    public var completed: Int
    /// Total number of people in this scan run.
    public var total: Int
    /// Display name of the person this event concerns: the one just finished, or the one about
    /// to be researched.
    public var currentName: String?
    /// Set (to a backend name, e.g. "DuckDuckGo") while a probe is backing off after that
    /// backend returned a challenge/CAPTCHA response; `nil` at every other time.
    public var waitingFor: String?
    /// `true` only on the final event of the stream, once every person has finished (or the
    /// scan was cancelled and no more will be scheduled).
    public var finished: Bool

    public init(completed: Int, total: Int, currentName: String? = nil, waitingFor: String? = nil, finished: Bool = false) {
        self.completed = completed
        self.total = total
        self.currentName = currentName
        self.waitingFor = waitingFor
        self.finished = finished
    }
}
