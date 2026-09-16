import Foundation
import NaturalLanguage

/// Why an `Embedder` could not produce a vector.
public enum EmbedderError: Error, Sendable {
    /// The on-device contextual-embedding model assets aren't available (and couldn't be
    /// downloaded), so `NLContextualEmbedder` has nothing to embed with.
    case unavailable
}

/// Turns text into a dense vector, for semantic similarity between people's profiles.
public protocol Embedder: Sendable {
    func embed(_ text: String) async throws -> [Float]
}

/// Embeds text using Apple's on-device `NLContextualEmbedding` model, mean-pooling its
/// per-token vectors into a single vector per input.
///
/// `NLContextualEmbedding` is a reference type that is neither `Sendable` nor safe to load or
/// query concurrently, so the model itself lives behind a private actor (`ModelBox`) that
/// serializes every access to it — including the load itself, via `OnceLoader` below, so that
/// concurrent `embed` calls share exactly one load attempt (one `requestAssets()`/`load()`
/// pair) instead of each re-entering the load sequence and redoing it. `NLContextualEmbedder`
/// is a thin `Sendable` struct wrapping that actor.
public struct NLContextualEmbedder: Embedder {
    private let box = ModelBox()

    public init() {}

    public func embed(_ text: String) async throws -> [Float] {
        try await box.embed(text)
    }

    /// Owns the once-loaded `NLContextualEmbedding` model and serializes access to it.
    private actor ModelBox {
        /// `NLContextualEmbedding` isn't `Sendable`, so it can't be `OnceLoader`'s `T` as-is —
        /// `Task.value` requires a `Sendable` result to cross back out of the task it's
        /// memoized in. It's wrapped in `UncheckedSendable` instead: the model is created
        /// fresh *inside* this closure (nothing pre-existing is captured, so the closure is a
        /// legitimate `@Sendable` value in the first place), and from that point on it's only
        /// ever reachable through `OnceLoader`'s own actor-serialized memoization — nothing
        /// else holds a competing reference to it.
        private let loader = OnceLoader<UncheckedSendable<NLContextualEmbedding>> {
            let embedding = NLContextualEmbedding(language: .english)!

            if !embedding.hasAvailableAssets {
                let result = try await embedding.requestAssets()
                guard result == .available else {
                    throw EmbedderError.unavailable
                }
            }

            try embedding.load()
            return UncheckedSendable(embedding)
        }

        func embed(_ text: String) async throws -> [Float] {
            let model = try await loader.value().value
            let dimension = model.dimension

            guard !text.isEmpty else {
                return [Float](repeating: 0, count: dimension)
            }

            let result = try model.embeddingResult(for: text, language: .english)

            var sum = [Double](repeating: 0, count: dimension)
            var tokenCount = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                for i in 0..<min(dimension, vector.count) {
                    sum[i] += vector[i]
                }
                tokenCount += 1
                return true
            }

            guard tokenCount > 0 else {
                return [Float](repeating: 0, count: dimension)
            }

            let divisor = Double(tokenCount)
            return sum.map { Float($0 / divisor) }
        }
    }
}

/// Wraps a non-`Sendable` value for the one legitimate crossing `OnceLoader` needs to make: a
/// freshly-created value, with no outside aliases at creation time, handed from the `Task` that
/// created it back to whichever caller awaits `OnceLoader.value()`. Safe only under that
/// discipline — this is not a general-purpose "make anything Sendable" escape hatch.
struct UncheckedSendable<Wrapped>: @unchecked Sendable {
    let value: Wrapped
    init(_ value: Wrapped) { self.value = value }
}

/// Memoizes a single async, possibly-failing load so concurrent callers share exactly one
/// in-flight attempt instead of each racing to redo the (possibly expensive, possibly
/// non-reentrant) work. A load that throws is not cached — it clears itself so the next call
/// retries from scratch.
actor OnceLoader<T: Sendable> {
    private let load: @Sendable () async throws -> T
    private var task: Task<T, Error>?

    init(_ load: @Sendable @escaping () async throws -> T) {
        self.load = load
    }

    func value() async throws -> T {
        if let task {
            return try await task.value
        }

        let newTask = Task { try await load() }
        task = newTask

        do {
            return try await newTask.value
        } catch {
            // Always safe: `task` only ever transitions nil -> non-nil synchronously (the
            // check above and this assignment have no `await` between them), so no concurrent
            // caller could have raced in and replaced `newTask` with a newer attempt while we
            // were suspended awaiting it — `task` here is still exactly the attempt that just
            // failed, never a newer one.
            task = nil
            throw error
        }
    }
}

/// Deterministic bag-of-words hashing embedder: used in tests (no model download needed) and
/// as the runtime fallback when `NLContextualEmbedder` throws `.unavailable`.
///
/// Each token is hashed with FNV-1a (stable across runs and processes, unlike
/// `String.hashValue`, which is randomized per process launch) into a bucket in `[0,
/// dimensions)`; a separate, high-order bit of the same hash picks the bucket's sign. The
/// resulting bag-of-words vector is then L2-normalized.
public struct HashEmbedder: Embedder {
    public let dimensions: Int

    public init(dimensions: Int = 64) {
        self.dimensions = dimensions
    }

    public func embed(_ text: String) async throws -> [Float] {
        var vector = [Float](repeating: 0, count: dimensions)

        let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        for token in tokens {
            let hash = Self.fnv1a64(token)
            let bucket = Int(hash % UInt64(dimensions))
            // Bit 63 (the hash's high end) picks the sign; the bucket index above is derived
            // from `hash % dimensions`, which — especially for a power-of-two `dimensions` —
            // is dominated by the *low* bits, so this keeps sign and bucket decorrelated.
            let sign: Float = (hash >> 63) & 1 == 0 ? 1 : -1
            vector[bucket] += sign
        }

        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// FNV-1a, 64-bit: deterministic across runs/processes, which `String.hashValue` is not.
    private static func fnv1a64<S: StringProtocol>(_ string: S) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }
}

/// Cosine similarity between two vectors.
public enum Vector {
    /// Returns 0 when either vector's norm is 0 or the two vectors have different lengths,
    /// rather than dividing by zero or comparing vectors from different embedding spaces.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        guard normA > 0, normB > 0 else { return 0 }
        return dot / (sqrt(normA) * sqrt(normB))
    }
}
