import Foundation

/// Talks to anything that speaks OpenAI's `/chat/completions`: the free and paid clouds in
/// the catalogue, plus every local runner (Ollama, LM Studio, llama.cpp, …), which is why
/// this one provider covers most of the catalogue.
///
/// Structured output is requested with `response_format: json_schema` in strict mode.
/// Plenty of OpenAI-compatible servers implement the endpoint but not that field, so a 400
/// that names it is answered by retrying once in plain JSON mode with the schema pasted into
/// the system prompt — the same request, degraded, rather than a failed call. That fallback
/// belongs to `complete`, so it covers every schema the app asks for, not just extraction.
public struct OpenAICompatibleProvider: AIProvider {
    public let spec: ProviderSpec
    private let baseURL: String
    private let apiKey: String?
    private let model: String
    private let extraHeaders: [String: String]
    private let client: any HTTPClient

    public init(
        spec: ProviderSpec,
        baseURL: String,
        apiKey: String?,
        model: String,
        extraHeaders: [String: String] = [:],
        client: any HTTPClient
    ) {
        self.spec = spec
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.extraHeaders = extraHeaders
        self.client = client
    }

    public func complete(
        system: String,
        user: String,
        schemaJSON: String,
        schemaName: String
    ) async throws -> Data {
        let schema = try SchemaJSON.value(schemaJSON)
        do {
            return try await send(system: system, user: user, schema: schema, schemaName: schemaName)
        } catch let error as HTTPError {
            guard case .status(400, let body) = error, mentionsSchemaSupport(body) else {
                throw ProviderError.from(error)
            }
            let relaxedSystem = "\(system)\n\nReturn only JSON matching this schema:\n\(schemaJSON)"
            do {
                return try await send(system: relaxedSystem, user: user, schema: nil, schemaName: schemaName)
            } catch let retryError as HTTPError {
                throw ProviderError.from(retryError)
            }
        }
    }

    /// One `/chat/completions` round trip. A `schema` asks for strict structured output;
    /// `nil` asks for plain JSON mode. Throws `HTTPError` untouched so the caller can decide
    /// between retrying and mapping, and `ProviderError` for anything about the answer's shape.
    private func send(system: String, user: String, schema: Any?, schemaName: String) async throws -> Data {
        guard let url = URL(string: "\(baseURL.trimmingTrailingSlashes())/chat/completions") else {
            throw ProviderError.badResponse("invalid base URL: \(baseURL)")
        }

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0,
        ]
        if let schema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": schemaName,
                    "strict": true,
                    "schema": schema,
                ] as [String: Any],
            ]
        } else {
            body["response_format"] = ["type": "json_object"]
        }

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            throw ProviderError.badResponse("could not encode request: \(error)")
        }

        var headers = extraHeaders
        headers["Content-Type"] = "application/json"
        if let apiKey, !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }

        let response = try await client.post(url, headers: headers, body: data)
        return try parse(response)
    }

    /// The assistant message's content as the bytes the caller decodes.
    private func parse(_ response: HTTPResponse) throws -> Data {
        let envelope = try? JSONSerialization.jsonObject(with: response.body)
        guard
            let choices = (envelope as? [String: Any])?["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            throw ProviderError.badResponse("unexpected response: \(response.text.prefix(300))")
        }

        if let content = message["content"] as? String, !content.isEmpty {
            return Data(content.utf8)
        }
        // A strict-mode model that declines answers with `refusal` and a null `content`.
        if let refusal = message["refusal"] as? String, !refusal.isEmpty {
            throw ProviderError.badResponse(refusal)
        }
        throw ProviderError.badResponse("empty response from \(spec.name)")
    }

    /// True when a 400's body blames the structured-output request rather than the prompt.
    private func mentionsSchemaSupport(_ body: String) -> Bool {
        let lowercased = body.lowercased()
        return lowercased.contains("response_format") || lowercased.contains("json_schema")
    }
}

extension String {
    /// Trims trailing `/` so a base URL pasted with or without one builds the same path.
    func trimmingTrailingSlashes() -> String {
        var trimmed = Substring(self)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }
}
