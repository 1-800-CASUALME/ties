import Foundation

/// Splits long text into model-sized pieces along natural boundaries.
///
/// Budgets are expressed in tokens and converted with the usual rough English ratio of
/// ~4 characters per token, which is close enough for sizing a prompt and keeps the
/// chunker free of any tokenizer dependency.
///
/// Splitting always happens at a boundary the text already contains — paragraph, line,
/// sentence, then word — so a chunk never ends mid-word. Rejoining the chunks with a
/// single space reproduces the input apart from the whitespace at the split points.
public enum TextChunker {
    /// Separators tried in order, coarsest first. The first one that actually occurs in the
    /// text decides where this level of splitting happens.
    ///
    /// For the sentence separators the punctuation belongs to the sentence that precedes it,
    /// so it is re-attached to each piece and only the trailing space is treated as the
    /// (discardable) split point; `glue` is what rejoins pieces that end up in the same chunk.
    private static let separators: [(separator: String, keep: String, glue: String)] = [
        ("\n\n", "", "\n\n"),
        ("\n", "", "\n"),
        (". ", ".", " "),
        ("? ", "?", " "),
        ("! ", "!", " "),
        (" ", "", " "),
    ]

    /// Splits `text` into chunks of at most `maxTokens` tokens (~4 characters each).
    /// Chunks are trimmed and empty ones dropped, so an all-whitespace input yields `[]`.
    public static func chunks(_ text: String, maxTokens: Int) -> [String] {
        let limit = max(1, maxTokens) * 4
        return split(text, limit: limit)
    }

    /// Splits one run of text, recursing into finer separators for any piece that is still
    /// too large. A piece with no separator left in it (a single very long word) is emitted
    /// whole rather than cut mid-word.
    private static func split(_ text: String, limit: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > limit else { return [trimmed] }

        for (separator, keep, glue) in separators {
            let pieces = split(trimmed, on: separator, keeping: keep)
            guard pieces.count > 1 else { continue }
            return pack(pieces, limit: limit, glue: glue)
        }
        return [trimmed]
    }

    /// Splits on `separator`, re-attaching `keep` (the separator's non-whitespace prefix) to
    /// every piece but the last, which already carries whatever followed it in the input.
    private static func split(_ text: String, on separator: String, keeping keep: String) -> [String] {
        let pieces = text.components(separatedBy: separator)
        guard pieces.count > 1, !keep.isEmpty else { return pieces }
        return pieces.enumerated().map { index, piece in
            index == pieces.count - 1 ? piece : piece + keep
        }
    }

    /// Greedily fills chunks up to `limit`, joining pieces back together with `glue`.
    /// A single piece that is itself over the limit is re-split at the next finer boundary.
    private static func pack(_ pieces: [String], limit: Int, glue: String) -> [String] {
        var chunks: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
        }

        for piece in pieces {
            guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let candidate = current.isEmpty ? piece : current + glue + piece
            if candidate.count <= limit {
                current = candidate
                continue
            }
            flush()
            if piece.count <= limit {
                current = piece
            } else {
                chunks.append(contentsOf: split(piece, limit: limit))
            }
        }
        flush()
        return chunks
    }
}
