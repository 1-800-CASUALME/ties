import Foundation

/// Talks to Anthropic's Messages API.
///
/// Anthropic has no `response_format`, so the schema is offered as a single tool the model is
/// forced to call: the tool is named after the schema, `tool_choice` pins it, and the answer
/// arrives as that tool call's `input` rather than as message text.
public struct AnthropicProvider: AIProvider {
    /// The API version header Anthropic requires on every request.
    private static let apiVersion = "2023-06-01"
    private static let endpoint = "https://api.anthropic.com/v1/messages"

    public let spec: ProviderSpec
    private let apiKey: String
    private let model: String
    private let client: any HTTPClient

    public init(spec: ProviderSpec, apiKey: String, model: String, client: any HTTPClient) {
        self.spec = spec
        self.apiKey = apiKey
        self.model = model
        self.client = client
    }

    public func complete(
        system: String,
        user: String,
        schemaJSON: String,
        schemaName: String
    ) async throws -> Data {
        guard let url = URL(string: Self.endpoint) else {
            throw ProviderError.badResponse("invalid endpoint: \(Self.endpoint)")
        }

        let schema = try SchemaJSON.value(schemaJSON)
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1_500,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "tools": [[
                "name": schemaName,
                "description": "Return the result as this tool's input",
                "input_schema": schema,
            ] as [String: Any]],
            "tool_choice": ["type": "tool", "name": schemaName],
        ]

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            throw ProviderError.badResponse("could not encode request: \(error)")
        }

        let headers = [
            "x-api-key": apiKey,
            "anthropic-version": Self.apiVersion,
            "content-type": "application/json",
        ]

        let response: HTTPResponse
        do {
            response = try await client.post(url, headers: headers, body: data)
        } catch let error as HTTPError {
            throw ProviderError.from(error)
        }
        return try parse(response, toolName: schemaName)
    }

    /// The forced tool call's `input`, re-serialised as the JSON bytes the caller decodes.
    private func parse(_ response: HTTPResponse, toolName: String) throws -> Data {
        let envelope = try? JSONSerialization.jsonObject(with: response.body)
        guard let content = (envelope as? [String: Any])?["content"] as? [[String: Any]] else {
            throw ProviderError.badResponse("unexpected response: \(response.text.prefix(300))")
        }
        // The model may narrate before calling the tool, so take the first tool_use block
        // rather than the first block.
        guard
            let call = content.first(where: { $0["type"] as? String == "tool_use" }),
            let input = call["input"],
            let inputData = try? JSONSerialization.data(withJSONObject: input)
        else {
            throw ProviderError.badResponse("no \(toolName) tool call in response: \(response.text.prefix(300))")
        }
        return inputData
    }
}
