import Foundation

/// A `SearchBackend` over the Exa search API.
public struct ExaSearchBackend: SearchBackend {
    public let id = "exa"

    private let apiKey: String
    private let client: any HTTPClient

    public init(apiKey: String, client: any HTTPClient) {
        self.apiKey = apiKey
        self.client = client
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        guard let url = URL(string: "https://api.exa.ai/search") else {
            throw SearchBackendError.transport("invalid Exa URL")
        }

        let body = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "numResults": 8,
            "type": "auto",
            "contents": ["text": ["maxCharacters": 400]],
        ])
        let headers = [
            "Content-Type": "application/json",
            "x-api-key": apiKey,
        ]

        let response: HTTPResponse
        do {
            response = try await client.post(url, headers: headers, body: body)
        } catch {
            throw mapSearchHTTPError(error)
        }

        let decoded = try JSONDecoder().decode(ExaResponse.self, from: response.body)
        return decoded.results.map { SearchHit(url: $0.url, title: $0.title, snippet: $0.text ?? "") }
    }
}

private struct ExaResponse: Decodable {
    struct Result: Decodable {
        var url: String
        var title: String
        var text: String?
    }
    var results: [Result]
}
