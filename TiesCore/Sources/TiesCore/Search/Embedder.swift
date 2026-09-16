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
/// serializes every access to it. `NLContextualEmbedder` is a thin `Sendable` struct wrapping
/// that actor.
public struct NLContextualEmbedder: Embedder {
    private let box = ModelBox()

    public init() {}

    public func embed(_ text: String) async throws -> [Float] {
        try await box.embed(text)
    }

    /// Owns the lazily-loaded `NLContextualEmbedding` model and serializes access to it.
    private actor ModelBox {
        private var model: NLContextualEmbedding?
        private var isLoaded = false

        func embed(_ text: String) async throws -> [Float] {
            let model = try await loadedModel()
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

        /// Loads the model on first use, requesting its assets first if they aren't already
        /// on-device. Cached after the first successful call so later `embed` calls don't
        /// re-check assets or reload.
        private func loadedModel() async throws -> NLContextualEmbedding {
            if let model, isLoaded { return model }

            let embedding = model ?? NLContextualEmbedding(language: .english)!
            model = embedding

            if !embedding.hasAvailableAssets {
                let result = try await embedding.requestAssets()
                if result == .notAvailable {
                    throw EmbedderError.unavailable
                }
            }

            try embedding.load()
            isLoaded = true
            return embedding
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
