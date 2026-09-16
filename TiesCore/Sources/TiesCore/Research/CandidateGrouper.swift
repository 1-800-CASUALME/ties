import Foundation

/// Groups `ProbeFinding`s that likely describe the same identity, so `CandidateScorer` can
/// score one candidate per group instead of one per finding.
public enum CandidateGrouper {
    /// Groups findings into identities: two findings are merged into the same group when their
    /// canonical `url` is equal, or they share a non-nil `username` (case-insensitive), or they
    /// share a non-nil `avatarURL`, or one finding's `linkedURLs` contains the other's `url`.
    ///
    /// Implemented as union-find over the findings' indices so merges chain transitively (e.g.
    /// A merges with B via a shared username, and B merges with C via a linked URL, puts A, B,
    /// and C all in one group). Groups are returned in order of first appearance: the order in
    /// which the first finding of each group appears in `findings`.
    public static func group(_ findings: [ProbeFinding]) -> [[ProbeFinding]] {
        let n = findings.count
        guard n > 0 else { return [] }

        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a)
            let rb = find(b)
            if ra != rb {
                parent[rb] = ra
            }
        }

        let canonicalURLs = findings.map { ProbeFinding.canonical($0.url) }
        let canonicalLinked = findings.map { $0.linkedURLs.map(ProbeFinding.canonical) }
        let usernames = findings.map { $0.username?.lowercased() }
        let avatars = findings.map(\.avatarURL)

        for i in 0..<n {
            for j in (i + 1)..<n {
                var merge = canonicalURLs[i] == canonicalURLs[j]

                if !merge, let u1 = usernames[i], let u2 = usernames[j], u1 == u2 {
                    merge = true
                }
                if !merge, let a1 = avatars[i], let a2 = avatars[j], a1 == a2 {
                    merge = true
                }
                if !merge, canonicalLinked[i].contains(canonicalURLs[j]) {
                    merge = true
                }
                if !merge, canonicalLinked[j].contains(canonicalURLs[i]) {
                    merge = true
                }

                if merge {
                    union(i, j)
                }
            }
        }

        var groupsByRoot: [Int: [ProbeFinding]] = [:]
        var rootOrder: [Int] = []
        for i in 0..<n {
            let root = find(i)
            if groupsByRoot[root] == nil {
                groupsByRoot[root] = []
                rootOrder.append(root)
            }
            groupsByRoot[root]?.append(findings[i])
        }

        return rootOrder.compactMap { groupsByRoot[$0] }
    }
}
