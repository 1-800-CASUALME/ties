import Foundation

/// Twilio's Lookup v2 API: the name registered against a line, plus its carrier and type.
///
/// This is the documented, paid, consented version of "whose number is this". The caller name
/// comes from CNAM, the same database a phone shows a name from when it rings, so a hit is
/// registered against the line rather than saved by a crowd — and it is United States only.
/// Carrier and line type answer worldwide, and are worth having on their own: a number that is
/// a landline registered to a clinic tells the scorer as much as a name would.
public struct TwilioLookupProvider: LookupProvider {
    public let id = LookupCatalog.twilioId

    private let accountSID: String
    private let authToken: String
    private let client: any HTTPClient
    private let baseURL: String

    public init(
        accountSID: String,
        authToken: String,
        client: any HTTPClient,
        baseURL: String = "https://lookups.twilio.com/v2/PhoneNumbers"
    ) {
        self.accountSID = accountSID
        self.authToken = authToken
        self.client = client
        self.baseURL = baseURL
    }

    public func lookup(_ query: LookupQuery) async throws -> LookupResult? {
        // Lookup is a phone-number API; an address has nothing to ask it about, and asking
        // anyway would be billed.
        guard let phone = query.phoneE164, !phone.isEmpty else { return nil }
        guard !accountSID.isEmpty, !authToken.isEmpty else { throw LookupError.notConfigured }

        let encoded = phone.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? phone
        guard let url = URL(string: "\(baseURL)/\(encoded)?Fields=caller_name,line_type_intelligence") else {
            throw LookupError.malformed("Bad lookup URL")
        }

        let credentials = Data("\(accountSID):\(authToken)".utf8).base64EncodedString()
        let response: HTTPResponse
        do {
            response = try await client.get(url, headers: ["Authorization": "Basic \(credentials)"], bypassCache: true)
        } catch let error as HTTPError {
            // Twilio answers 404 for a number it cannot parse or has no record of. That is an
            // answer, not a failure: this person simply isn't in the database. `HTTPClient`
            // raises every status at or above 400, so the check belongs here rather than on a
            // response that never arrives.
            if case .status(404, _) = error { return nil }
            throw Self.translate(error)
        }

        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw LookupError.malformed("Lookup answered with something that isn't JSON")
        }

        var names: [LookupName] = []
        if let caller = json["caller_name"] as? [String: Any],
           let name = JSONPath.string(caller, field: "caller_name") {
            names.append(LookupName(value: name, kind: .registered))
        }

        let line = json["line_type_intelligence"] as? [String: Any]
        let result = LookupResult(
            names: names,
            carrier: line.flatMap { JSONPath.string($0, field: "carrier_name") },
            lineType: line.flatMap { JSONPath.string($0, field: "type") },
            providerId: id
        )
        return result.isEmpty ? nil : result
    }

    /// A transport failure carries the same meaning here as everywhere else in Ties; only the
    /// two that change what the caller should do next are worth distinguishing.
    static func translate(_ error: HTTPError) -> LookupError {
        switch error {
        case .rateLimited(let retryAfter): .rateLimited(retryAfter: retryAfter)
        case .status(let code, _) where code == 401 || code == 403: .unauthorized
        case .status(let code, _): .http(code)
        case .transport(let detail): .malformed(detail)
        case .timeout: .malformed("The lookup timed out")
        }
    }
}
