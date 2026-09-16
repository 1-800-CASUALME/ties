import Foundation

/// Reads the plain text out of Apple's `typedstream` archives — the format Messages writes into
/// `message.attributedBody` and, on recent macOS versions, the only place a message's words
/// exist (`message.text` is left NULL).
///
/// Only the string payload is decoded, not the whole archive: after the `NSString` class marker
/// comes a short run of type bytes (`0x01 0x94 0x84 0x01 '+'`), then the byte length of the
/// UTF-8 payload — or `0x81` followed by a little-endian `UInt16` length once the string passes
/// 127 bytes. Anything that doesn't fit that shape reads as `nil` rather than as garbage.
public enum TypedStream {
    /// The text of the archived string, or `nil` when `attributedBody` holds no readable one.
    public static func text(from attributedBody: Data) -> String? {
        let bytes = [UInt8](attributedBody)
        guard let markerEnd = index(after: classMarker, in: bytes) else { return nil }

        // The type bytes between the class name and the payload vary a little between macOS
        // versions, so the '+' that opens the string is searched for rather than skipped over.
        var index = markerEnd
        let searchLimit = min(bytes.count, markerEnd + markerSearchWindow)
        while index < searchLimit, bytes[index] != stringMarker { index += 1 }
        guard index < searchLimit else { return nil }
        index += 1

        guard index < bytes.count else { return nil }
        var length = Int(bytes[index])
        index += 1
        if length == Int(longLengthMarker) {
            guard index + 1 < bytes.count else { return nil }
            length = Int(bytes[index]) | Int(bytes[index + 1]) << 8
            index += 2
        } else if length >= 0x80 {
            return nil  // a length encoding we don't read; better nothing than half a message
        }

        guard length > 0, index + length <= bytes.count else { return nil }
        return String(bytes: bytes[index..<(index + length)], encoding: .utf8)
    }

    /// The class name that precedes the string payload in the archive.
    private static let classMarker = Array("NSString".utf8)
    /// Opens the payload.
    private static let stringMarker: UInt8 = 0x2B  // '+'
    /// Announces a two-byte little-endian length.
    private static let longLengthMarker: UInt8 = 0x81
    /// How far past the class name the payload marker may sit.
    private static let markerSearchWindow = 16

    /// The offset just past the first occurrence of `needle` in `haystack`, or `nil`.
    private static func index(after needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count)
        where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return start + needle.count
        }
        return nil
    }
}
