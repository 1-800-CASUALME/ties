import Foundation

/// Fans queries out over several search workers instead of queueing them all behind one.
///
/// Each worker is a whole engine of its own — in the app, one hidden `WKWebView` — so the pool
/// itself only has to decide *who* answers a query and what to do when one of them hits a bot
/// wall. Queries go round-robin, so two people being researched at once are searched at once.
///
/// Failover is per worker rather than per pool: a worker that throws `.challenge` is moved onto
/// the next engine and left alone for `failoverCooldown` (ten minutes by default), and the query
/// it refused is retried once on somebody else. Only when every worker is cooling down does the
/// pool itself throw `.challenge`, which is the signal `SearchProbe` and the scanner already
/// know how to back off on.
public actor SearchPool: SearchBackend {
    public nonisolated let id = "pool"

    /// One worker and what the pool knows about it: which engine it is on, and when it may be
    /// asked again.
    private struct Slot {
        let worker: any SearchBackend
        var engineIndex: Int
        /// When this worker's cooldown ends, or `nil` when it isn't cooling down at all.
        var coolingUntil: ContinuousClock.Instant?
    }

    private var slots: [Slot]
    /// The engines a challenged worker can be moved onto, in order. Disabled engines are
    /// dropped here, once, so failover never points a web view at a page the spike found
    /// unscrapable.
    private let engines: [SearchEngine]
    private let failoverCooldown: Duration
    private let clock = ContinuousClock()
    /// Where the next query starts looking for a worker; advanced past whoever takes it.
    private var cursor = 0

    public init(
        workers: [any SearchBackend],
        engines: [SearchEngine],
        failoverCooldown: Duration = .seconds(600)
    ) {
        self.slots = workers.map { Slot(worker: $0, engineIndex: 0, coolingUntil: nil) }
        self.engines = engines.filter(\.enabled)
        self.failoverCooldown = failoverCooldown
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        // Two attempts: the one the query was dispatched to, and — if that one turned out to
        // be behind a bot wall — one retry somewhere else. A third would just be walking the
        // pool into the same wall on a worse engine.
        for _ in 0..<2 {
            // Checked before the dispatch and again before the retry: a scan that has been
            // stopped shouldn't spend a worker's turn, and a retry is a fresh query as far as
            // the engine is concerned.
            try Task.checkCancellation()
            guard let index = nextAvailableSlot() else { throw SearchBackendError.challenge }
            let worker = slots[index].worker
            do {
                return try await worker.search(query)
            } catch SearchBackendError.challenge {
                // A bot wall is about the engine, not the query: cool this worker down, move
                // it on, and let the loop hand the query to someone else.
                await failOver(index)
            }
            // Every other error — a timeout, a transport failure — is this query's problem
            // rather than this worker's, and is thrown on to the caller unchanged.
        }
        throw SearchBackendError.challenge
    }

    /// The next worker in the rotation that isn't cooling down, advancing the cursor past it.
    /// `nil` when every worker is cooling down (or there are none at all).
    private func nextAvailableSlot() -> Int? {
        guard !slots.isEmpty else { return nil }
        let now = clock.now
        for offset in 0..<slots.count {
            let index = (cursor + offset) % slots.count
            if let coolingUntil = slots[index].coolingUntil, now < coolingUntil { continue }
            slots[index].coolingUntil = nil
            cursor = (index + 1) % slots.count
            return index
        }
        return nil
    }

    /// Cools a challenged worker down and moves it onto the next engine, which it will use for
    /// its next query — by which time the cooldown will have passed. With only one engine
    /// enabled there is nowhere to move it to, so it just sits out the cooldown.
    private func failOver(_ index: Int) async {
        slots[index].coolingUntil = clock.now.advanced(by: failoverCooldown)
        guard engines.count > 1 else { return }

        let next = (slots[index].engineIndex + 1) % engines.count
        slots[index].engineIndex = next
        if let switchable = slots[index].worker as? any SearchEngineSwitching {
            await switchable.switchEngine(engines[next])
        }
    }

    // MARK: - Pacing

    /// How long a worker waits before its next query: `base` seconds give or take `jitter`,
    /// never less than a second.
    ///
    /// The jitter is what keeps two or three web views from settling into lockstep and
    /// knocking on the same engine at the same instant, forever. It lives here, rather than in
    /// the app's web-view backend, so the arithmetic that decides how hard Ties leans on a
    /// search engine is somewhere it can be tested.
    ///
    /// `random` is a seam for those tests; it is handed the `-jitter...jitter` range and
    /// returns the offset to use.
    public static func nextInterval(
        base: TimeInterval,
        jitter: TimeInterval,
        random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) -> TimeInterval {
        let offset = jitter > 0 ? random(-jitter...jitter) : 0
        return max(1.0, base + offset)
    }
}
