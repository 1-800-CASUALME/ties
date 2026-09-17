import Foundation

/// A very small path language for reaching into a JSON response whose shape Ties doesn't know
/// until the user describes it.
///
/// `result.tags[]` walks `result`, then `tags`, then yields each element of that array. A
/// segment with no `[]` steps into one value; a segment with `[]` fans out over an array, and
/// everything after it applies to each element. A leading `[]` fans out over a top-level array.
///
/// It exists for `CustomLookupProvider`, where the user maps their own service's response onto
/// names and tags. Deliberately not a JSONPath implementation: filters and wildcards would be a
/// query language to document and get wrong, and every lookup response worth reading is a list
/// of objects or a list of strings.
enum JSONPath {
    /// Every node the path reaches. An empty path yields the root.
    static func nodes(_ path: String, in json: Any) -> [Any] {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [json] }

        var current: [Any] = [json]
        for segment in trimmed.split(separator: ".") {
            var key = String(segment)
            let fansOut = key.hasSuffix("[]")
            if fansOut { key = String(key.dropLast(2)) }

            var next: [Any] = []
            for node in current {
                // An empty key is the `[]` segment on its own: fan out over the node itself.
                let value: Any? = key.isEmpty ? node : (node as? [String: Any])?[key]
                guard let value, !(value is NSNull) else { continue }
                if fansOut, let array = value as? [Any] {
                    next.append(contentsOf: array)
                } else {
                    next.append(value)
                }
            }
            current = next
        }
        return current
    }

    /// The string at `field` of `node`, or `node` itself when `field` is nil and the node is a
    /// string. Numbers and booleans are not names, and are ignored rather than stringified —
    /// a mis-typed path should come back empty, not fill the chips with `1` and `true`.
    static func string(_ node: Any, field: String?) -> String? {
        let value: Any? = field.map { (node as? [String: Any])?[$0] } ?? node
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The integer at `field` of `node`, for the services that say how many people saved a name.
    static func int(_ node: Any, field: String?) -> Int? {
        guard let field else { return node as? Int }
        guard let dictionary = node as? [String: Any] else { return nil }
        if let number = dictionary[field] as? NSNumber { return number.intValue }
        if let text = dictionary[field] as? String { return Int(text) }
        return nil
    }
}
