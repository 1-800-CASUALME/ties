import Foundation

/// Whatever lookup service the user already has access to, described rather than coded.
///
/// The user gives a URL with `{phone}` in it, the header their key goes in, and two `JSONPath`s
/// saying where the names and the labels sit in the answer. Ties calls it, reads those two
/// places, and puts what it finds beside what Messages, WhatsApp and Mail found. Nothing about
/// any particular service is built in here — no endpoint, no token format, no vendor's private
/// API — which is what keeps this a slot the user fills rather than a scraper Ties ships.
public struct CustomLookupProvider: LookupProvider {
    /// Which catalogue entry this is standing in for. Every described endpoint is served by this
    /// one type, so the id comes from the entry rather than being fixed here — otherwise every
    /// answer would claim to have come from "custom" whatever the user picked.
    public let id: String

    private let config: CustomLookupConfig
    private let key: String?
    private let client: any HTTPClient

    public init(
        id: String = LookupCatalog.customId,
        config: CustomLookupConfig,
        key: String?,
        client: any HTTPClient
    ) {
        self.id = id
        self.config = config
        self.key = key
        self.client = client
    }

    public func lookup(_ query: LookupQuery) async throws -> LookupResult? {
        let filled = LookupCatalog.fill(config.urlTemplate, with: query)
        // Nothing was substituted: either the template has no placeholder, or it asks for a
        // channel this person hasn't got. Both mean the same request would go out for everyone
        // — and be billed for everyone — so it doesn't go out at all.
        guard filled != config.urlTemplate else { throw LookupError.notConfigured }
        guard let url = URL(string: filled), url.scheme != nil else {
            throw LookupError.malformed("Lookup URL isn't a URL: \(filled)")
        }

        var headers: [String: String] = ["Accept": "application/json"]
        if let name = config.headerName, !name.isEmpty, let key, !key.isEmpty {
            headers[name] = config.headerTemplate.replacingOccurrences(of: "{key}", with: key)
        }

        let response: HTTPResponse
        do {
            response = try await client.get(url, headers: headers, bypassCache: true)
        } catch let error as HTTPError {
            // A service that has nothing on this number says so with a 404, which `HTTPClient`
            // raises rather than returns. It is an answer: no names, no error to report.
            if case .status(404, _) = error { return nil }
            throw TwilioLookupProvider.translate(error)
        }

        guard let json = try? JSONSerialization.jsonObject(with: response.body) else {
            throw LookupError.malformed("The service answered with something that isn't JSON")
        }
        let result = parse(json)
        return result.isEmpty ? nil : result
    }

    /// Reads the two configured paths out of a decoded response. Kept separate from the call so
    /// a user can be shown exactly what Ties would take from a sample answer.
    func parse(_ json: Any) -> LookupResult {
        let kind: LookupNameKind = config.namesAreCrowd ? .crowd : .registered
        var names: [LookupName] = []
        var seen = Set<String>()
        // An empty path would resolve to the whole response, so a half-filled configuration is
        // read as "this service has no names" rather than as one enormous name.
        for node in config.namesPath.isEmpty ? [] : JSONPath.nodes(config.namesPath, in: json) {
            guard let value = JSONPath.string(node, field: config.nameField) else { continue }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { continue }
            names.append(LookupName(value: value, kind: kind, count: JSONPath.int(node, field: config.countField)))
        }

        var tags: [String] = []
        var seenTags = Set<String>()
        for node in config.tagsPath.isEmpty ? [] : JSONPath.nodes(config.tagsPath, in: json) {
            guard let value = JSONPath.string(node, field: config.tagField) else { continue }
            guard seenTags.insert(value.lowercased()).inserted else { continue }
            tags.append(value)
        }

        // Most used first, so a name fifty people agree on outranks one person's typo of it.
        names.sort { ($0.count ?? 0) > ($1.count ?? 0) }
        return LookupResult(names: names, tags: tags, providerId: id)
    }
}
