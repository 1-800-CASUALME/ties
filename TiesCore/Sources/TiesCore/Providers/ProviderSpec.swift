import Foundation

/// Wire protocol used to talk to a provider.
public enum Transport: String, Codable, Sendable {
    case appleFoundation, openAIChat, anthropic, claudeCLI, codexCLI, geminiCLI
}

/// Where and how a provider runs, used to group the catalogue for display.
public enum ProviderTier: String, Codable, Sendable {
    case onDevice, freeCloud, cli, local, paidCloud, custom
}

/// How `ProviderDetector` checks whether a provider is usable on this Mac.
public enum DetectRule: Sendable, Hashable {
    /// On-device Apple Intelligence.
    case appleIntelligence
    /// An app bundle name (e.g. `"Jan.app"`), checked at `/Applications/<name>` and
    /// `~/Applications/<name>`.
    case appBundle(String)
    /// A CLI executable name (e.g. `"claude"`), resolved via the login shell's `PATH`
    /// and a few well-known install locations.
    case executable(String)
    /// A local HTTP server health/status URL, probed with a short-timeout GET.
    case http(String)
}

/// Static description of one AI provider in the catalogue: how to reach it, what it costs,
/// and how to detect whether it is already available on this Mac.
public struct ProviderSpec: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    /// Asset name in `ProviderLogos` (equal to `id` for every catalogue entry).
    public let logo: String
    public let transport: Transport
    public let tier: ProviderTier
    public let defaultBaseURL: String?
    public let defaultModel: String?
    public let apiKeyURL: String?
    public let detect: DetectRule?
    public let needsAPIKey: Bool
    public let supportsJSONSchema: Bool

    public init(
        id: String,
        name: String,
        logo: String,
        transport: Transport,
        tier: ProviderTier,
        defaultBaseURL: String? = nil,
        defaultModel: String? = nil,
        apiKeyURL: String? = nil,
        detect: DetectRule? = nil,
        needsAPIKey: Bool = true,
        supportsJSONSchema: Bool = true
    ) {
        self.id = id
        self.name = name
        self.logo = logo
        self.transport = transport
        self.tier = tier
        self.defaultBaseURL = defaultBaseURL
        self.defaultModel = defaultModel
        self.apiKeyURL = apiKeyURL
        self.detect = detect
        self.needsAPIKey = needsAPIKey
        self.supportsJSONSchema = supportsJSONSchema
    }
}

/// Per-provider user overrides (custom base URL/model/headers), persisted as JSON in
/// `UserDefaults` under the key `"providerConfigs"`.
public struct ProviderConfig: Codable, Sendable, Hashable {
    public var id: String
    public var baseURL: String?
    public var model: String?
    public var extraHeaders: [String: String]

    public init(id: String, baseURL: String? = nil, model: String? = nil, extraHeaders: [String: String] = [:]) {
        self.id = id
        self.baseURL = baseURL
        self.model = model
        self.extraHeaders = extraHeaders
    }
}
