import Foundation

/// The parsed tail of a mail body: what a signature block says about its sender.
public struct SignatureBlock: Sendable, Hashable {
    public var name: String?
    public var titles: [String]
    public var companies: [String]
    public var phones: [String]
    public var links: [String]
    public var location: String?

    public init(
        name: String? = nil,
        titles: [String] = [],
        companies: [String] = [],
        phones: [String] = [],
        links: [String] = [],
        location: String? = nil
    ) {
        self.name = name
        self.titles = titles
        self.companies = companies
        self.phones = phones
        self.links = links
        self.location = location
    }
}

/// Pure text rules that turn chat and mail text into signals: honorifics, aliases, mail
/// signature blocks and shared links. No I/O, no database, no model calls — every rule here is
/// a deterministic function of its input (spec §4.2).
public enum SignalRules {
    // MARK: - Tuning

    /// How far a capitalised candidate may sit from a handle or name mention and still count as
    /// an alias for that person, in characters.
    static let aliasProximity = 40

    /// Above this `NameMatcher.similarity`, a candidate is just the person's known name again
    /// rather than an alias for it. The one gate for every "is this only their name?" decision:
    /// the alias rule below, the WhatsApp push name, the Contacts nickname, and the `From`
    /// display name in mail all ask it, so one answer cannot disagree with another.
    public static let aliasNameGate = 0.9

    /// A name holding one of these tokens names an organisation rather than a person or a group
    /// of friends — the rule behind `looksLikeCompany`.
    private static let companyTokens: Set<String> = ["inc", "llc", "ltd", "team", "co", "شركة"]

    /// The most lines of a mail body tail that can make up a signature block.
    static let signatureLineLimit = 8

    /// More links than this and the "signature" is a newsletter footer.
    static let signatureLinkLimit = 3

    // MARK: - Honorifics

    /// The canonical honorifics (`"dr"`, `"eng"`, …) appearing immediately before a token of one
    /// of `names`, deduped in first-seen order.
    public static func honorifics(in text: String, names: [String]) -> [String] {
        let nameTokens = Set(names.flatMap(normalizedTokens))
        guard !nameTokens.isEmpty else { return [] }

        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var found: [String] = []
        for index in tokens.indices.dropFirst() {
            guard nameTokens.contains(NameMatcher.normalize(tokens[index])),
                  let canonical = Honorifics.canonical(tokens[index - 1]),
                  !found.contains(canonical)
            else { continue }
            found.append(canonical)
        }
        return found
    }

    // MARK: - Aliases

    /// Capitalised 1–3 word names that recur near a mention of `names` or of a handle-like
    /// (`@…`, `+…`) token, and that are not one of `names` themselves — the group-chat nickname
    /// for a person. A candidate must occur at least `minOccurrences` times to count.
    public static func aliases(in text: String, names: [String], minOccurrences: Int = 3) -> [String] {
        let anchors = anchorRanges(in: text, names: names)
        guard !anchors.isEmpty else { return [] }
        let nameTokens = Set(names.flatMap(normalizedTokens))

        var order: [String] = []
        var counts: [String: Int] = [:]
        var spellings: [String: String] = [:]

        for match in text.matches(of: titleCaseRun) where isNear(match.range, to: anchors, in: text) {
            var words = String(match.output).split(whereSeparator: \.isWhitespace).map(String.init)
            while let first = words.first, stopWords.contains(first.lowercased()) {
                words.removeFirst()
            }
            guard !words.isEmpty, words.count <= 3 else { continue }

            // The whole run is the likeliest alias ("Abu Khalid"), but a run can also be a
            // greeting glued to one ("Hey Sarita"), so each word is a candidate of its own.
            var candidates = [words.joined(separator: " ")]
            if words.count > 1 { candidates.append(contentsOf: words) }

            for candidate in candidates where isAliasCandidate(candidate, names: names, nameTokens: nameTokens) {
                let key = candidate.lowercased()
                counts[key, default: 0] += 1
                if spellings[key] == nil {
                    spellings[key] = candidate
                    order.append(key)
                }
            }
        }
        return order.filter { counts[$0, default: 0] >= minOccurrences }.compactMap { spellings[$0] }
    }

    // MARK: - Signature

    /// Parses the signature block at the end of a mail body: the last ≤ 8 non-empty lines after
    /// the last sign-off marker (or after the last line that is the sender's own name). Returns
    /// `nil` for newsletters, quoted replies, and blocks holding no title, company, phone or
    /// link.
    public static func signature(in body: String, senderName: String?) -> SignatureBlock? {
        let sender = senderName?.trimmingCharacters(in: .whitespaces)
        let lines = body.components(separatedBy: .newlines)

        var delimiter: Int?
        var delimiterIsSenderName = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.firstMatch(of: signOffMarker) != nil {
                delimiter = index
                delimiterIsSenderName = false
            } else if let sender, !sender.isEmpty, trimmed.caseInsensitiveCompare(sender) == .orderedSame {
                delimiter = index
                delimiterIsSenderName = true
            }
        }

        // With no marker at all, the tail of the body is still the likeliest place for a
        // signature; the rejection rules below decide whether it really is one.
        let tail = delimiter.map { Array(lines.dropFirst($0 + 1)) } ?? lines
        let block = Array(
            tail.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .suffix(signatureLineLimit)
        )
        guard !block.isEmpty else { return nil }
        guard !block.contains(where: isQuoted) else { return nil }
        guard block.reduce(0, { $0 + $1.matches(of: urlPattern).count }) <= signatureLinkLimit else { return nil }

        var name = delimiterIsSenderName ? sender : nil
        var titles: [String] = []
        var companies: [String] = []
        var phones: [String] = []
        var links: [String] = []
        var location: String?
        // A bare profession line ("Engineer") is the stacked layout, whose next line is the
        // company rather than a place.
        var expectingCompany = false

        // The block line that carried the person's name, so a title line next to it is read as
        // theirs; -1 is the delimiter line itself, immediately above the block.
        var nameLine: Int? = delimiterIsSenderName ? -1 : nil

        for (index, line) in block.enumerated() {
            var rest = line
            for candidate in linkCandidates(in: line) {
                if let canonical = canonicalLink(trimmingTrailingPunctuation(candidate.url)),
                   !links.contains(canonical) {
                    links.append(canonical)
                }
                rest = rest.replacingOccurrences(of: candidate.text, with: " ")
            }
            for raw in rest.matches(of: phonePattern).map({ String($0.output) }) {
                guard let e164 = PhoneNormalizer.e164(raw, defaultRegion: "SA")
                    ?? PhoneNormalizer.e164(raw, defaultRegion: "US")
                else { continue }
                if !phones.contains(e164) { phones.append(e164) }
                rest = rest.replacingOccurrences(of: raw, with: " ")
            }

            let remainder = rest.trimmingCharacters(in: .whitespaces)
            guard !remainder.isEmpty else { continue }
            if let sender, remainder.caseInsensitiveCompare(sender) == .orderedSame {
                name = sender
                nameLine = index
                continue
            }

            // "Sara Ahmed, Cardiologist at King Faisal Hospital": a leading person name only
            // counts as one when what follows still parses as title + company.
            var subject = remainder
            if let comma = remainder.firstIndex(of: ",") {
                let head = String(remainder[..<comma]).trimmingCharacters(in: .whitespaces)
                let afterComma = String(remainder[remainder.index(after: comma)...])
                    .trimmingCharacters(in: .whitespaces)
                if looksLikePersonName(head), titleAndCompany(in: afterComma) != nil {
                    if name == nil { name = head }
                    nameLine = index
                    subject = afterComma
                }
            }

            // A separator alone does not make a title: "Katherine at Acme" is a person and a
            // place, not a job. Keep the parse when the title names a profession, or when this
            // line sits right under the person's own name, which is where titles live.
            if let parsed = titleAndCompany(in: subject),
               containsProfession(parsed.title) || nameLine == index || nameLine == index - 1 {
                if !titles.contains(parsed.title) { titles.append(parsed.title) }
                if !companies.contains(parsed.company) { companies.append(parsed.company) }
                expectingCompany = false
            } else if containsProfession(subject) {
                if !titles.contains(subject) { titles.append(subject) }
                expectingCompany = true
            } else if name == nil, !expectingCompany, looksLikePersonName(subject) {
                name = subject
                nameLine = index
            } else if expectingCompany, subject.count <= 60 {
                if !companies.contains(subject) { companies.append(subject) }
                expectingCompany = false
            } else if location == nil, subject.firstMatch(of: locationPattern) != nil,
                      subject != name, !companies.contains(subject) {
                location = subject
            }
        }

        guard !titles.isEmpty || !companies.isEmpty || !phones.isEmpty || !links.isEmpty else { return nil }
        return SignatureBlock(
            name: name,
            titles: titles,
            companies: companies,
            phones: phones,
            links: links,
            location: location
        )
    }

    // MARK: - Links

    /// The canonical identity URLs in `text`: `linkedin.com/in/…`, `x.com`, `twitter.com` and
    /// `github.com` profiles — written with a scheme or without one, as they are in chat — plus
    /// any other `https` URL whose path is at most two segments deep. Tracking query strings are
    /// dropped and hosts are lowercased, deduped in first-seen order.
    public static func links(in text: String) -> [String] {
        var found: [String] = []
        for candidate in linkCandidates(in: text) {
            guard let canonical = canonicalLink(trimmingTrailingPunctuation(candidate.url)),
                  !found.contains(canonical)
            else { continue }
            found.append(canonical)
        }
        return found
    }

    /// Every link mention in `text`, in the order they appear: full `http(s)` URLs, plus bare
    /// `linkedin.com/in/…`-style mentions of the known identity hosts, which people write
    /// without a scheme. `text` is the substring as written, `url` the same with a scheme.
    private static func linkCandidates(in text: String) -> [(text: String, url: String)] {
        var candidates = text.matches(of: urlPattern).map { ($0.range, String($0.output), String($0.output)) }
        for match in text.matches(of: schemelessIdentityPattern) {
            let mention = String(match.output.1)
            candidates.append((match.range, mention, "https://" + mention))
        }
        return candidates
            .sorted { $0.0.lowerBound < $1.0.lowerBound }
            .map { (text: $0.1, url: $0.2) }
    }

    // MARK: - Patterns

    // A literal `Regex` holds an immutable compiled program and no captured state of its own,
    // so matching the same value from several tasks is safe; `Regex` is simply not annotated
    // `Sendable` because a regex built with custom components could capture anything.
    nonisolated(unsafe) private static let urlPattern = #/https?://[^\s<>"')\]]+/#
    nonisolated(unsafe) private static let phonePattern = #/\+?\d[\d\s().\-]{5,20}\d/#
    nonisolated(unsafe) private static let titleCaseRun = #/[A-Z][a-z'’\-]+(?:\s+[A-Z][a-z'’\-]+)*/#
    nonisolated(unsafe) private static let handlePattern = #/[@+][A-Za-z0-9._\-]{2,}/#
    nonisolated(unsafe) private static let locationPattern = #/^[A-Z][a-z]+(,\s*[A-Z][a-z ]+)?$/#
    // Separators need their own whitespace, or "Senator" splits into "Sen" / "or" and "Chief Cat
    // Officer" splits inside "Cat": `at` and the dashes must stand alone between spaces, a pipe
    // or comma must carry whitespace on at least one side, and only `@` may sit flush against
    // both. The title is lazy, so the separator nearest the start of the line wins, and the
    // alternatives are listed in the order they are preferred at any one position.
    nonisolated(unsafe) private static let titlePattern =
        #/^(?<title>[^|,@]{3,60}?)(?:\s+\|\s*|\|\s+|\s*,\s+|\s+[-–]\s+|\s+[Aa][Tt]\s+|\s*@\s*)(?<company>[^|,]{2,60})$/#

    /// The same identity hosts as `identityHosts`, written without a scheme the way people
    /// mention them in chat. The leading boundary keeps this off the tail of a full URL.
    nonisolated(unsafe) private static let schemelessIdentityPattern =
        #/(?:^|[\s(,;])((?:www\.)?(?:linkedin\.com|x\.com|twitter\.com|github\.com)/[^\s<>"')\]]+)/#
            .ignoresCase()
    nonisolated(unsafe) private static let signOffMarker =
        #/^(--\s?|regards|best|thanks|kind regards|cheers|sincerely|تحياتي|مع التحية)\p{P}*$/#.ignoresCase()

    /// Capitalised words that open a sentence far more often than they name anyone.
    private static let stopWords: Set<String> = [
        "the", "this", "that", "these", "those", "there", "here", "hi", "hey", "hello", "dear",
        "thanks", "thank", "ok", "okay", "yes", "no", "please", "sorry", "good", "morning",
        "evening", "today", "tomorrow", "yesterday", "and", "but", "so", "if", "when", "what",
        "why", "how", "who", "we", "you", "they", "he", "she", "it", "let", "see", "sent", "from",
    ]

    /// Identity hosts whose profile URLs are worth keeping whatever their casing or scheme.
    private static let identityHosts = ["linkedin.com", "x.com", "twitter.com", "github.com"]

    // MARK: - Chat names

    /// True when a chat or group name reads like an organisation ("Acme Inc", "Clinic Team",
    /// "شركة النور") rather than a group of friends. Messages reads it off `chat.display_name`
    /// and WhatsApp off `ZWACHATSESSION.ZPARTNERNAME`, so the rule lives here rather than in
    /// either collector.
    public static func looksLikeCompany(_ name: String) -> Bool {
        name.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .contains { companyTokens.contains($0) }
    }

    // MARK: - Helpers

    private static func normalizedTokens(_ name: String) -> [String] {
        NameMatcher.normalize(name).split(separator: " ").map(String.init).filter { $0.count >= 2 }
    }

    /// Ranges that make a nearby capitalised word likely to be about this person: handle-like
    /// tokens, and mentions of any token of a known name.
    private static func anchorRanges(in text: String, names: [String]) -> [Range<String.Index>] {
        var ranges = text.matches(of: handlePattern).map(\.range)
        for token in Set(names.flatMap(normalizedTokens)) {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(
                      of: token,
                      options: [.caseInsensitive, .diacriticInsensitive],
                      range: searchStart..<text.endIndex
                  ) {
                ranges.append(found)
                searchStart = found.upperBound
            }
        }
        return ranges
    }

    private static func isNear(
        _ range: Range<String.Index>,
        to anchors: [Range<String.Index>],
        in text: String
    ) -> Bool {
        anchors.contains { anchor in
            if anchor.overlaps(range) { return true }
            if anchor.upperBound <= range.lowerBound {
                return text.distance(from: anchor.upperBound, to: range.lowerBound) <= aliasProximity
            }
            return text.distance(from: range.upperBound, to: anchor.lowerBound) <= aliasProximity
        }
    }

    private static func isAliasCandidate(_ candidate: String, names: [String], nameTokens: Set<String>) -> Bool {
        guard candidate.count <= 30, looksLikePersonName(candidate) else { return false }
        let words = candidate.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard !words.contains(where: stopWords.contains) else { return false }
        guard Honorifics.canonical(candidate) == nil else { return false }

        let normalized = NameMatcher.normalize(candidate)
        guard !normalized.isEmpty, !nameTokens.contains(normalized) else { return false }
        return !names.contains {
            NameMatcher.similarity(personName: $0, candidateName: candidate) >= aliasNameGate
        }
    }

    private static func looksLikePersonName(_ s: String) -> Bool {
        guard s.count <= 30 else { return false }
        let words = s.split(whereSeparator: \.isWhitespace).map(String.init)
        return (1...3).contains(words.count) && words.allSatisfy(isCapitalisedWord)
    }

    private static func isCapitalisedWord(_ word: String) -> Bool {
        guard word.count >= 2, let first = word.first, first.isUppercase else { return false }
        return word.dropFirst().allSatisfy { $0.isLowercase || $0 == "'" || $0 == "’" || $0 == "-" }
    }

    private static func isQuoted(_ line: String) -> Bool {
        line.hasPrefix(">") || line.range(of: "wrote:", options: .caseInsensitive) != nil
    }

    private static func titleAndCompany(in line: String) -> (title: String, company: String)? {
        guard let match = line.firstMatch(of: titlePattern) else { return nil }
        let title = String(match.output.title).trimmingCharacters(in: .whitespaces)
        let company = String(match.output.company).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !company.isEmpty else { return nil }
        return (title, company)
    }

    /// True when a line names a profession: an English profession word, or — since Arabic writes
    /// the job itself where English abbreviates it — an honorific token in either language, so
    /// "مهندسة برمجيات" reads as a title.
    private static func containsProfession(_ line: String) -> Bool {
        let words = Set(NameMatcher.normalize(line).split(separator: " ").map(String.init))
        if !words.isDisjoint(with: Honorifics.allProfessions) { return true }
        return line.split(whereSeparator: \.isWhitespace).contains { Honorifics.canonical(String($0)) != nil }
    }

    private static func trimmingTrailingPunctuation(_ url: String) -> String {
        var trimmed = Substring(url)
        while let last = trimmed.last, ".,;:!?)]}'\"".contains(last) {
            trimmed = trimmed.dropLast()
        }
        return String(trimmed)
    }

    /// Canonicalises one URL and decides whether it is identity-shaped enough to keep.
    private static func canonicalLink(_ raw: String) -> String? {
        let canonical = ProbeFinding.canonical(raw)
        guard var components = URLComponents(string: canonical), let host = components.host?.lowercased() else {
            return nil
        }
        let segments = components.path.split(separator: "/").map(String.init)

        if let identity = identityHosts.first(where: { host == $0 || host.hasSuffix("." + $0) }) {
            if identity == "linkedin.com" {
                guard segments.count == 2, segments[0].lowercased() == "in" else { return nil }
            } else {
                guard (1...2).contains(segments.count) else { return nil }
            }
            // Profile slugs on these hosts are case-insensitive, so one person yields one URL.
            components.scheme = "https"
            components.host = host
            components.path = "/" + segments.map { $0.lowercased() }.joined(separator: "/")
            return components.string
        }

        guard components.scheme == "https", segments.count <= 2 else { return nil }
        return canonical
    }
}
