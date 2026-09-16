import Foundation

/// A `SearchBackend` over the Tavily search API.
public struct TavilySearchBackend: SearchBackend {
    public let id = "tavily"

    private let apiKey: String
    private let client: any HTTPClient

    public init(apiKey: String, client: any HTTPClient) {
        self.apiKey = apiKey
        self.client = client
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        guard let url = URL(string: "https://api.tavily.com/search") else {
            throw SearchBackendError.transport("invalid Tavily URL")
        }

        let body = try JSONSerialization.data(withJSONObject: [
            "api_key": apiKey,
            "query": query,
            "max_results": 8,
            "include_answer": false,
        ])
        let headers = [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(apiKey)",
        ]

        let response: HTTPResponse
        do {
            response = try await client.post(url, headers: headers, body: body)
        } catch {
            throw mapSearchHTTPError(error)
        }

        let decoded = try JSONDecoder().decode(TavilyResponse.self, from: response.body)
        return decoded.results.map { SearchHit(url: $0.url, title: $0.title, snippet: $0.content) }
    }
}

private struct TavilyResponse: Decodable {
    struct Result: Decodable {
        var url: String
        var title: String
        var content: String
    }
    var results: [Result]
}
