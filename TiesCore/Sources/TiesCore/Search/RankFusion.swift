import Foundation

/// Reciprocal rank fusion: blends several ranked id lists (e.g. keyword hits and semantic
/// hits) into one ranking without needing the lists' scores to be on comparable scales.
public enum RankFusion {
    /// Fuses `lists` into a single ranking. Each list is a set of ids in rank order (rank 1 is
    /// the first element); an id's fused score is the sum, over every list it appears in, of
    /// `1 / (k + rank)`. Results are sorted by score descending; ties are broken by the id's
    /// earliest first-appearance across `lists` (in list order, then position within a list),
    /// so the result is deterministic regardless of the ids' original hashing/ordering.
    public static func rrf(_ lists: [[String]], k: Double = 60) -> [(id: String, score: Double)] {
        var scores: [String: Double] = [:]
        var firstAppearance: [String: Int] = [:]
        var order = 0

        for list in lists {
            for (index, id) in list.enumerated() {
                let rank = index + 1
                scores[id, default: 0] += 1 / (k + Double(rank))
                if firstAppearance[id] == nil {
                    firstAppearance[id] = order
                    order += 1
                }
            }
        }

        return scores.keys.sorted { lhs, rhs in
            let lScore = scores[lhs] ?? 0
            let rScore = scores[rhs] ?? 0
            if lScore != rScore { return lScore > rScore }
            return (firstAppearance[lhs] ?? 0) < (firstAppearance[rhs] ?? 0)
        }.map { (id: $0, score: scores[$0] ?? 0) }
    }
}
