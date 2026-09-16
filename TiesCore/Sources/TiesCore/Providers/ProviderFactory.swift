import Foundation

/// Builds the right `AIProvider` for a catalogue entry from the user's settings.
///
/// Apple Intelligence is passed in as a closure because `FoundationModels` only exists in
/// the app target: TiesCore knows the provider belongs in the catalogue, the app supplies it.
public enum ProviderFactory {
    public static func make(
        spec: ProviderSpec,
        config: ProviderConfig?,
        apiKey: String?,
        detected: DetectResult,
        client: any HTTPClient,
        apple: (@Sendable () -> (any AIProvider)?)? = nil
    ) throws -> any AIProvider {
        switch spec.transport {
        case .appleFoundation:
            guard let provider = apple?() else { throw ProviderError.unavailable("Apple Intelligence") }
            return provider

        case .openAIChat:
            guard let baseURL = nonEmpty(config?.baseURL) ?? nonEmpty(spec.defaultBaseURL) else {
                throw ProviderError.badResponse("missing base URL")
            }
            return OpenAICompatibleProvider(
                spec: spec,
                baseURL: baseURL,
                apiKey: apiKey,
                model: nonEmpty(config?.model) ?? spec.defaultModel ?? "",
                extraHeaders: config?.extraHeaders ?? [:],
                client: client
            )

        case .anthropic:
            guard let apiKey = nonEmpty(apiKey) else { throw ProviderError.unauthorized }
            return AnthropicProvider(
                spec: spec,
                apiKey: apiKey,
                model: nonEmpty(config?.model) ?? spec.defaultModel ?? "",
                client: client
            )

        case .claudeCLI:
            let executable = try executable(spec: spec, detected: detected)
            if let model = nonEmpty(config?.model) {
                return ClaudeCLIProvider(spec: spec, executable: executable, model: model)
            }
            return ClaudeCLIProvider(spec: spec, executable: executable)

        case .codexCLI:
            return CodexCLIProvider(spec: spec, executable: try executable(spec: spec, detected: detected))

        case .geminiCLI:
            return GeminiCLIProvider(spec: spec, executable: try executable(spec: spec, detected: detected))
        }
    }

    /// The detected path of a CLI provider's tool, or `.notInstalled` if detection never
    /// found one.
    private static func executable(spec: ProviderSpec, detected: DetectResult) throws -> String {
        guard case .available(let path) = detected, !path.isEmpty else {
            throw ProviderError.notInstalled(spec.name)
        }
        return path
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
