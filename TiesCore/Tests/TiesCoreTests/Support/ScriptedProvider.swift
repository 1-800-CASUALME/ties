import Foundation
@testable import TiesCore

/// An `AIProvider` that answers from a queued script instead of a model, and records every
/// call it was asked to make.
///
/// The recording is the point: an AI service's behaviour is half what it does with the reply
/// and half what it puts in the prompt (the §7.5 privacy rule is only observable there), so
/// tests assert on `calls` as much as on return values. Replies are consumed in order, so one
/// provider can play both halves of a two-call flow (extraction, then fact check).
/// Not `private`/`fileprivate`: reused across AI test files.
final class ScriptedProvider: AIProvider, @unchecked Sendable {
    /// One recorded `complete` call, exactly as the service made it.
    struct Call: Sendable {
        var system: String
        var user: String
        var schemaJSON: String
        var schemaName: String
    }

    enum Reply {
        case json(String)
        case failure(any Error)
    }

    let spec: ProviderSpec
    /// How long each call takes to answer. Set it longer than a caller's timeout to make the
    /// caller give up on this provider.
    let latency: Duration?

    private var replies: [Reply]
    private var recorded: [Call] = []
    private let lock = NSLock()

    init(
        spec: ProviderSpec = ProviderCatalog.spec("custom")!,
        replies: [String] = [],
        latency: Duration? = nil
    ) {
        self.spec = spec
        self.replies = replies.map { .json($0) }
        self.latency = latency
    }

    init(spec: ProviderSpec = ProviderCatalog.spec("custom")!, failure: any Error) {
        self.spec = spec
        self.replies = [.failure(failure)]
        self.latency = nil
    }

    /// Every call made so far, in order.
    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func complete(system: String, user: String, schemaJSON: String, schemaName: String) async throws -> Data {
        if let latency { try await Task.sleep(for: latency) }
        return try next(Call(system: system, user: user, schemaJSON: schemaJSON, schemaName: schemaName))
    }

    func validate() async throws {}

    /// `NSLock.lock()`/`unlock()` are `noasync`, so the bookkeeping lives in a plain
    /// synchronous helper the `async` `complete` above calls (same shape as `FakeHTTP`).
    private func next(_ call: Call) throws -> Data {
        lock.lock()
        recorded.append(call)
        let reply = replies.isEmpty ? nil : replies.removeFirst()
        lock.unlock()

        switch reply {
        case .json(let text): return Data(text.utf8)
        case .failure(let error): throw error
        case nil: throw ProviderError.badResponse("ScriptedProvider ran out of replies")
        }
    }
}

/// A provider failure a test can throw and recognise.
struct ScriptedFailure: Error {}
