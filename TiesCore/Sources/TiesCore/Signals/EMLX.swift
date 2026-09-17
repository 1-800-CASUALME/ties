import Foundation
import SwiftSoup

/// One message read out of a `.emlx` file: who wrote it, who it went to, when, and its body as
/// plain text. Mail's own metadata plist is not represented — nothing there is a signal.
public struct EMLXMessage: Sendable {
    /// The `From` display name (RFC 2047 decoded) and its lowercased address.
    public var from: (name: String?, address: String)?
    /// Lowercased `To` and `Cc` addresses, in header order.
    public var to: [String]
    /// Parsed for completeness; collectors never store it (spec §10).
    public var subject: String?
    public var date: Date?
    /// The first `text/plain` part of the message, or the first `text/html` part with its markup
    /// stripped down to lines.
    public var textBody: String

    public init(
        from: (name: String?, address: String)? = nil,
        to: [String] = [],
        subject: String? = nil,
        date: Date? = nil,
        textBody: String = ""
    ) {
        self.from = from
        self.to = to
        self.subject = subject
        self.date = date
        self.textBody = textBody
    }
}

/// Reads Mail's on-disk message format: a byte-count line, that many bytes of RFC 822 message,
/// then a property list of Mail's own flags that this parser ignores.
public enum EMLX {
    /// A `multipart/*` tree this deep is a mail loop, not a message.
    private static let maxDepth = 10

    // MARK: - Entry point

    public static func parse(_ data: Data) throws -> EMLXMessage {
        guard let newline = data.firstIndex(of: Byte.lineFeed) else {
            throw SourceError.malformed("no byte-count line")
        }
        let countText = text(Data(data[data.startIndex..<newline])).trimmingCharacters(in: .whitespaces)
        guard let count = Int(countText), count >= 0 else {
            throw SourceError.malformed("byte count is not a number: \(countText)")
        }
        let start = data.index(after: newline)
        let end = data.index(start, offsetBy: count, limitedBy: data.endIndex) ?? data.endIndex
        return parse(rfc822: Data(data[start..<end]))
    }

    /// The bare RFC 822 message, without the `.emlx` wrapper — also the shape of every MIME part.
    static func parse(rfc822 data: Data) -> EMLXMessage {
        let (headerData, bodyData) = splitHeaders(data)
        let headers = Headers(headerData)

        let bodies = textParts(headers: headers, body: bodyData, depth: 0)
        let plain = bodies.plain ?? bodies.html.flatMap { try? plainText(html: $0) } ?? ""

        return EMLXMessage(
            from: headers.value("from").flatMap { addresses(in: $0).first },
            to: (headers.values("to") + headers.values("cc")).flatMap { addresses(in: $0) }.map(\.address),
            subject: headers.value("subject").map(decodeEncodedWords),
            date: headers.value("date").flatMap(date(from:)),
            textBody: plain
        )
    }

    // MARK: - Headers

    /// The header fields of one message or MIME part, unfolded (a line opening with whitespace
    /// continues the one before it) and looked up case-insensitively.
    struct Headers {
        private let fields: [(name: String, value: String)]

        init(_ data: Data) {
            var fields: [(name: String, value: String)] = []
            for line in EMLX.text(data).components(separatedBy: "\n") {
                let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
                if let first = line.first, first == " " || first == "\t" {
                    if !fields.isEmpty { fields[fields.count - 1].value += line }
                    continue
                }
                guard let colon = line.firstIndex(of: ":") else { continue }
                fields.append((
                    name: String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased(),
                    value: String(line[line.index(after: colon)...])
                ))
            }
            self.fields = fields
        }

        func value(_ name: String) -> String? {
            fields.first { $0.name == name }.map { $0.value.trimmingCharacters(in: .whitespaces) }
        }

        func values(_ name: String) -> [String] {
            fields.filter { $0.name == name }.map { $0.value.trimmingCharacters(in: .whitespaces) }
        }
    }

    /// Splits a message or part at the blank line that ends its headers.
    private static func splitHeaders(_ data: Data) -> (headers: Data, body: Data) {
        var index = data.startIndex
        while let newline = data[index...].firstIndex(of: Byte.lineFeed) {
            let afterNewline = data.index(after: newline)
            guard afterNewline < data.endIndex else { break }
            if data[afterNewline] == Byte.lineFeed {
                return (Data(data[data.startIndex..<newline]), Data(data[data.index(after: afterNewline)...]))
            }
            if data[afterNewline] == Byte.carriageReturn {
                let third = data.index(after: afterNewline)
                if third < data.endIndex, data[third] == Byte.lineFeed {
                    return (Data(data[data.startIndex..<newline]), Data(data[data.index(after: third)...]))
                }
            }
            index = afterNewline
        }
        return (data, Data())
    }

    // MARK: - Addresses

    /// The `Name <address>` entries of one address-list header. Addresses are lowercased, since
    /// that is how every channel in the app is normalized.
    static func addresses(in list: String) -> [(name: String?, address: String)] {
        var entries: [String] = []
        var current = ""
        var inQuotes = false
        var inAngles = false
        for character in list {
            switch character {
            case "\"": inQuotes.toggle()
            case "<" where !inQuotes: inAngles = true
            case ">" where !inQuotes: inAngles = false
            case "," where !inQuotes && !inAngles:
                entries.append(current)
                current = ""
                continue
            default: break
            }
            current.append(character)
        }
        entries.append(current)

        return entries.compactMap { entry in
            let entry = entry.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { return nil }
            guard let open = entry.firstIndex(of: "<"), let close = entry[open...].firstIndex(of: ">") else {
                let address = entry.lowercased()
                return address.contains("@") ? (nil, address) : nil
            }
            let address = String(entry[entry.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            var name = String(entry[..<open]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast())
            }
            name = decodeEncodedWords(name).trimmingCharacters(in: .whitespaces)
            return (name.isEmpty ? nil : name, address.lowercased())
        }
    }

    // MARK: - Dates

    // `DateFormatter` is thread-safe once configured, and these are never mutated after this
    // line, so one shared set serves every parse.
    private static let dateFormatters: [DateFormatter] = [
        "EEE, d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm Z",
        "d MMM yyyy HH:mm Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "d MMM yyyy HH:mm:ss zzz",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = format
        return formatter
    }

    static func date(from raw: String) -> Date? {
        // "Tue, 1 Sep 2026 10:00:00 +0300 (AST)" — the trailing zone comment is not parseable.
        var cleaned = raw
        if let comment = cleaned.firstIndex(of: "(") { cleaned = String(cleaned[..<comment]) }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        for formatter in dateFormatters {
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }

    // MARK: - MIME

    /// The first `text/plain` and the first `text/html` body anywhere in this entity's tree.
    private static func textParts(headers: Headers, body: Data, depth: Int) -> (plain: String?, html: String?) {
        let type = contentType(headers)

        if type.mime.hasPrefix("multipart/"), let boundary = type.parameters["boundary"], depth < maxDepth {
            var plain: String?
            var html: String?
            for part in split(body, boundary: boundary) {
                let (partHeaders, partBody) = splitHeaders(part)
                let found = textParts(headers: Headers(partHeaders), body: partBody, depth: depth + 1)
                plain = plain ?? found.plain
                html = html ?? found.html
                if plain != nil, html != nil { break }
            }
            return (plain, html)
        }

        guard type.mime.hasPrefix("text/") else { return (nil, nil) }
        // An attached .txt or .html file is a document, not something the person wrote inline.
        if headers.value("content-disposition")?.lowercased().hasPrefix("attachment") == true {
            return (nil, nil)
        }
        let decoded = decode(body, transferEncoding: headers.value("content-transfer-encoding"))
        let text = string(from: decoded, charset: type.parameters["charset"])
        return type.mime == "text/html" ? (nil, text) : (text, nil)
    }

    /// `text/plain` when unstated, as RFC 2045 requires.
    private static func contentType(_ headers: Headers) -> (mime: String, parameters: [String: String]) {
        guard let raw = headers.value("content-type") else { return ("text/plain", [:]) }
        let pieces = splitParameters(raw)
        var parameters: [String: String] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = String(piece[..<equals]).trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(piece[piece.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            parameters[key] = value
        }
        return (pieces.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "text/plain", parameters)
    }

    /// Splits a structured header value on `;`, ignoring separators inside quoted strings.
    private static func splitParameters(_ value: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        for character in value {
            if character == "\"" { inQuotes.toggle() }
            if character == ";", !inQuotes {
                pieces.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        pieces.append(current)
        return pieces
    }

    /// The bodies between `--boundary` delimiter lines, without the closing `--boundary--`.
    private static func split(_ data: Data, boundary: String) -> [Data] {
        let marker = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var partStart: Data.Index?
        var searchStart = data.startIndex

        while searchStart < data.endIndex,
              let found = data.range(of: marker, in: searchStart..<data.endIndex) {
            let atLineStart = found.lowerBound == data.startIndex
                || data[data.index(before: found.lowerBound)] == Byte.lineFeed
            guard atLineStart else {
                searchStart = found.upperBound
                continue
            }
            if let start = partStart {
                var end = found.lowerBound
                // The CRLF in front of a delimiter belongs to the delimiter, not to the part.
                if end > start, data[data.index(before: end)] == Byte.lineFeed { end = data.index(before: end) }
                if end > start, data[data.index(before: end)] == Byte.carriageReturn { end = data.index(before: end) }
                parts.append(Data(data[start..<end]))
            }
            var afterMarker = found.upperBound
            if afterMarker < data.endIndex, data[afterMarker] == Byte.hyphen {
                partStart = nil
                break
            }
            while afterMarker < data.endIndex, data[afterMarker] != Byte.lineFeed {
                afterMarker = data.index(after: afterMarker)
            }
            if afterMarker < data.endIndex { afterMarker = data.index(after: afterMarker) }
            partStart = afterMarker
            searchStart = afterMarker
        }
        if let start = partStart, start < data.endIndex { parts.append(Data(data[start...])) }
        return parts
    }

    // MARK: - Transfer encodings

    static func decode(_ data: Data, transferEncoding: String?) -> Data {
        switch transferEncoding?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "quoted-printable": return decodeQuotedPrintable(data)
        case "base64": return Data(base64Encoded: data, options: .ignoreUnknownCharacters) ?? data
        default: return data
        }
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == Byte.equals else {
                out.append(bytes[index])
                index += 1
                continue
            }
            // A soft line break: "=" at end of line, joining the next line to this one.
            if index + 1 < bytes.count, bytes[index + 1] == Byte.lineFeed {
                index += 2
                continue
            }
            if index + 2 < bytes.count, bytes[index + 1] == Byte.carriageReturn, bytes[index + 2] == Byte.lineFeed {
                index += 3
                continue
            }
            if index + 2 < bytes.count,
               let high = hexDigit(bytes[index + 1]),
               let low = hexDigit(bytes[index + 2]) {
                out.append(high << 4 | low)
                index += 3
                continue
            }
            out.append(bytes[index])
            index += 1
        }
        return Data(out)
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    // MARK: - Charsets

    /// UTF-8 unless the part says Latin-1 (or says nothing and isn't valid UTF-8) — the two
    /// charsets that between them cover the mail worth reading signals out of.
    static func string(from data: Data, charset: String?) -> String {
        let name = (charset ?? "utf-8").lowercased()
        if name.contains("8859") || name.contains("latin") || name.contains("windows-125") {
            return String(data: data, encoding: .isoLatin1) ?? text(data)
        }
        return text(data)
    }

    private static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - RFC 2047

    /// Decodes `=?UTF-8?B?…?=` and `=?UTF-8?Q?…?=` words in a header value. Whitespace between
    /// two adjacent encoded words is a separator the encoder added, so it is dropped.
    static func decodeEncodedWords(_ raw: String) -> String {
        guard raw.contains("=?") else { return raw }
        var result = ""
        var pendingSpace = ""
        var lastWasEncoded = false
        var index = raw.startIndex

        while index < raw.endIndex {
            if raw[index...].hasPrefix("=?"), let word = encodedWord(in: raw, at: index) {
                if !lastWasEncoded { result += pendingSpace }
                pendingSpace = ""
                result += word.text
                index = word.end
                lastWasEncoded = true
                continue
            }
            let character = raw[index]
            if character.isWhitespace {
                pendingSpace.append(character)
            } else {
                result += pendingSpace
                pendingSpace = ""
                result.append(character)
                lastWasEncoded = false
            }
            index = raw.index(after: index)
        }
        return result + pendingSpace
    }

    private static func encodedWord(in raw: String, at start: String.Index) -> (text: String, end: String.Index)? {
        let charsetStart = raw.index(start, offsetBy: 2)
        guard let charsetEnd = raw[charsetStart...].firstIndex(of: "?") else { return nil }
        let encodingStart = raw.index(after: charsetEnd)
        guard encodingStart < raw.endIndex, let encodingEnd = raw[encodingStart...].firstIndex(of: "?") else {
            return nil
        }
        let payloadStart = raw.index(after: encodingEnd)
        guard let terminator = raw.range(of: "?=", range: payloadStart..<raw.endIndex) else { return nil }

        // "UTF-8*en" — the optional language tag is not part of the charset name.
        let charset = String(raw[charsetStart..<charsetEnd]).components(separatedBy: "*")[0]
        let payload = String(raw[payloadStart..<terminator.lowerBound])
        let decoded: Data?
        switch raw[encodingStart..<encodingEnd].lowercased() {
        case "b": decoded = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        // In a "Q" word an underscore stands for a space.
        case "q": decoded = decodeQuotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
        default: return nil
        }
        guard let decoded else { return nil }
        return (string(from: decoded, charset: charset), terminator.upperBound)
    }

    // MARK: - HTML

    /// Elements that end the line they are on, so an HTML signature laid out in `<div>`s still
    /// reads as one line per fact to `SignalRules`.
    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "div", "dd", "dl", "dt", "fieldset",
        "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li",
        "main", "nav", "ol", "p", "pre", "section", "table", "tbody", "td", "tfoot", "th",
        "thead", "tr", "ul",
    ]

    /// Markup reduced to text with its line structure intact. `ReadableText` is the web-page
    /// equivalent, but it keeps only long paragraphs — exactly the lines a signature is not.
    static func plainText(html: String) throws -> String {
        let document = try SwiftSoup.parse(html)
        try document.select("script, style, head, title").remove()
        var out = ""
        appendText(of: document, to: &out)

        let lines = out.replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var kept: [String] = []
        for line in lines where !(line.isEmpty && kept.last?.isEmpty != false) {
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appendText(of node: Node, to out: inout String) {
        for child in node.getChildNodes() {
            if let text = child as? TextNode {
                out += text.text()
                continue
            }
            guard let element = child as? Element else { continue }
            let tag = element.tagName().lowercased()
            if tag == "br" {
                out += "\n"
                continue
            }
            if tag == "a" {
                var inner = ""
                appendText(of: element, to: &inner)
                out += inner
                // A hyperlinked "LinkedIn" hides the URL that is the whole point of the link.
                if let href = try? element.attr("href"), href.hasPrefix("http"), !inner.contains(href) {
                    out += " <\(href)>"
                }
                continue
            }
            let isBlock = blockTags.contains(tag)
            if isBlock, !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
            appendText(of: element, to: &out)
            if isBlock, !out.hasSuffix("\n") { out += "\n" }
        }
    }

    // MARK: - Bytes

    private enum Byte {
        static let lineFeed: UInt8 = 0x0A
        static let carriageReturn: UInt8 = 0x0D
        static let equals: UInt8 = 0x3D
        static let hyphen: UInt8 = 0x2D
    }
}
