import Foundation

/// Fans queries out over several search workers instead of queueing them all behind one.
///
/// Each worker is a whole engine of its own — in the app, one hidden `WKWebView` — so the pool
/// itself only has to decide *who* answers a query and what to do when one of them hits a bot
/// wall. Queries go round-robin, so two people being researched at once are searched at once.
///
/// A worker answers one query at a time. The scan runs more people at once than there are
/// workers, so without that rule every worker always has a query running and another queued
/// behind it, and the 2.5 s spacing each worker paces itself by is measured on a queue that
/// never drains. A caller that finds every worker busy waits for the first one to come free
/// instead of piling onto it.
///
/// Failover is per worker rather than per pool: a worker that throws `.challenge` is moved onto
/// the next engine and left alone for `failoverCooldown` (ten minutes by default), and the query
/// it refused is retried once on somebody else. Only when every worker is cooling down does the
/// pool itself throw `.challenge`, which is the signal `SearchProbe` and the scanner already
/// know how to back off on.
public actor SearchPool: SearchBackend {
    public nonisolated let id = "pool"

    /// One worker and what the pool knows about it: which engine it is on, whether it is
    /// answering a query right now, and when it may be asked again.
    private struct Slot {
        let worker: any SearchBackend
        var engineIndex: Int
        /// When this worker's cooldown ends, or `nil` when it isn't cooling down at all.
        var coolingUntil: ContinuousClock.Instant?
        /// True from the moment a query is handed to this worker until it answers, throws, or
        /// is failed over — the pool's guarantee that a worker is never given two at once.
        var busy = false
    }

    /// One caller parked until a worker frees up, resumed in arrival order.
    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Int?, Error>
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
    /// Callers waiting for a worker to come free, oldest first.
    private var waiting: [Waiter] = []
    private var nextWaiterId = 0

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
            guard let index = try await claimSlot() else { throw SearchBackendError.challenge }
            let worker = slots[index].worker
            do {
                let hits = try await worker.search(query)
                release(index)
                return hits
            } catch SearchBackendError.challenge {
                // A bot wall is about the engine, not the query: cool this worker down, move
                // it on, and let the loop hand the query to someone else.
                await failOver(index)
                release(index)
            } catch {
                // Every other error — a timeout, a transport failure — is this query's problem
                // rather than this worker's, and is thrown on to the caller unchanged. The
                // worker keeps its turn in the rotation, so it has to be let go of first.
                release(index)
                throw error
            }
        }
        throw SearchBackendError.challenge
    }

    // MARK: - Who answers

    /// A worker of the caller's own, marked busy until it is released: the next idle one in the
    /// rotation, or — when every worker is answering something already — the first to come free.
    ///
    /// `nil` only when there is nobody who could ever take the query: every worker is cooling
    /// down, or there are no workers at all. Waiting would deadlock in that case, so parked
    /// callers are woken with `nil` too if the last usable worker cools down under them.
    private func claimSlot() async throws -> Int? {
        if let index = takeIdleSlot() { return index }
        guard hasUsableWorker else { return nil }

        let id = nextWaiterId
        nextWaiterId += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int?, Error>) in
                waiting.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.stopWaiting(id) }
        }
    }

    /// The next worker in the rotation that is neither busy nor cooling down, marked busy and
    /// with the cursor advanced past it. `nil` when there is no such worker right now.
    private func takeIdleSlot() -> Int? {
        guard !slots.isEmpty else { return nil }
        for offset in 0..<slots.count {
            let index = (cursor + offset) % slots.count
            guard !slots[index].busy, !isCoolingDown(slots[index]) else { continue }
            slots[index].coolingUntil = nil
            slots[index].busy = true
            cursor = (index + 1) % slots.count
            return index
        }
        return nil
    }

    /// Hands the worker back and gives it to whoever has been waiting longest.
    private func release(_ index: Int) {
        slots[index].busy = false
        wakeWaiters()
    }

    private func wakeWaiters() {
        while !waiting.isEmpty {
            guard let index = takeIdleSlot() else {
                // Nothing is free. If nothing ever will be — every worker is cooling down —
                // the parked callers are told so rather than left hanging on a pool that has
                // stopped answering.
                if !hasUsableWorker {
                    let stranded = waiting
                    waiting.removeAll()
                    for waiter in stranded { waiter.continuation.resume(returning: nil) }
                }
                return
            }
            waiting.removeFirst().continuation.resume(returning: index)
        }
    }

    /// A caller whose task was cancelled while parked stops waiting for a worker it would only
    /// throw away.
    private func stopWaiting(_ id: Int) {
        guard let position = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: position).continuation.resume(throwing: CancellationError())
    }

    /// True when some worker could still take a query — it isn't cooling down, whether or not
    /// it is busy right now.
    private var hasUsableWorker: Bool {
        slots.contains { !isCoolingDown($0) }
    }

    private func isCoolingDown(_ slot: Slot) -> Bool {
        guard let coolingUntil = slot.coolingUntil else { return false }
        return clock.now < coolingUntil
    }

    /// Cools a challenged worker down and moves it onto the next engine, which it will use for
    /// its next query — by which time the cooldown will have passed. With only one engine
    /// enabled there is nowhere to move it to, so it just sits out the cooldown.
    private func failOver(_ index: Int) async {
        slots[index].coolingUntil = clock.now.advanced(by: failoverCooldown)
        // A worker that has just gone behind a bot wall may have been the last one anybody
        // waiting could have been given.
        if !hasUsableWorker { wakeWaiters() }
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
