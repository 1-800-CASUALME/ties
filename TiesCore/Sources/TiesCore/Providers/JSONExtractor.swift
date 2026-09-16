import Foundation

/// Pulls the one JSON object out of model text that was asked for JSON and answered with a
/// little more than that: a sentence of preamble, a ``` fence, a trailing "hope that helps".
///
/// Providers that can constrain the model (OpenAI's `json_schema`, Anthropic's tool input)
/// never need this; the CLIs and the on-device model, which can only be *asked* for JSON in
/// the prompt, always do.
public enum JSONExtractor {
    /// The first balanced `{…}` in `text`, as UTF-8 bytes, or `nil` if there is none.
    ///
    /// Braces inside JSON strings are skipped — `{"a":"}{"}` is one object, not a broken one —
    /// and a backslash escape hides whatever follows it, so an escaped quote does not end the
    /// string it sits in. An object that never closes yields `nil` rather than a truncated
    /// fragment, so a cut-off answer fails loudly instead of decoding into half a result.
    public static func firstObject(in text: String) -> Data? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false

        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"":
                inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                // A stray `}` before any `{` is prose, not the end of an object.
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let start {
                    return Data(text[start...index].utf8)
                }
            default:
                break
            }
        }
        return nil
    }
}
