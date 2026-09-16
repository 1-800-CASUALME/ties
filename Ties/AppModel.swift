import AppKit
import Foundation
import Observation
import TiesCore

/// The app's single long-lived object graph: the open database, the shared HTTP client and
/// search backend, and the factories that build a provider, scanner, or extractor out of the
/// user's saved settings.
///
/// Everything here is `@MainActor` because the views own it; the pieces it hands out
/// (`Store`, `Scanner`, `Extractor`, probes) are `Sendable` and do their work off the main
/// actor themselves.
@MainActor
@Observable
final class AppModel {
    /// Keys this model reads and writes in `UserDefaults`. Provider base URL/model overrides
    /// use `providerConfigPrefix + <provider id>`.
    private enum Keys {
        static let hasCompletedSetup = "hasCompletedSetup"
        static let selectedProviderId = "selectedProviderId"
        static let searchBackend = "searchBackend"
        static let providerConfigPrefix = "providerConfig."
    }

    let store: Store
    let http: URLSessionHTTPClient
    let contacts = ContactsService()
    let searchBackend: any SearchBackend

    /// Starts as the on-device contextual model and is swapped for `HashEmbedder` by
    /// `warmEmbedder()` if that model can't be loaded.
    var embedder: any Embedder

    /// Query side of the index. Derived from `embedder` rather than stored, so a fallback can
    /// never leave searching and indexing on different vectors.
    var search: SearchService { SearchService(store: store, embedder: embedder) }

    /// What `ProviderDetector` last found for each provider id. Held in memory only: this
    /// describes the Mac right now (which CLIs are installed, which local server is up), not
    /// a preference worth persisting. The setup wizard fills it in before `makeProvider()`
    /// needs it.
    var detections: [String: DetectResult] = [:]

    private var setupCompleted: Bool
    private var providerId: String?
    private let defaults: UserDefaults

    /// Whether the setup wizard has been finished; `RootView` switches on it.
    var hasCompletedSetup: Bool {
        get { setupCompleted }
        set {
            setupCompleted = newValue
            defaults.set(newValue, forKey: Keys.hasCompletedSetup)
        }
    }

    /// The id of the chosen `ProviderCatalog` entry, or `nil` before the wizard picks one.
    var selectedProviderId: String? {
        get { providerId }
        set {
            providerId = newValue
            if let newValue {
                defaults.set(newValue, forKey: Keys.selectedProviderId)
            } else {
                defaults.removeObject(forKey: Keys.selectedProviderId)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        // `Store.open` creates the Application Support directory itself, so a first run has
        // nothing to prepare. Anything that still fails here (a corrupt file, a failed
        // migration) leaves the app with no database at all, which nothing downstream can
        // work around.
        let store: Store
        do {
            store = try Store.open(at: Store.defaultURL)
        } catch {
            fatalError("Ties could not open its database at \(Store.defaultURL.path): \(error)")
        }
        let http = URLSessionHTTPClient(cache: DiskCache(directory: DiskCache.defaultDirectory))
        let embedder = NLContextualEmbedder()

        self.defaults = defaults
        self.store = store
        self.http = http
        self.embedder = embedder
        self.searchBackend = AppModel.makeSearchBackend(defaults: defaults, client: http)
        self.setupCompleted = defaults.bool(forKey: Keys.hasCompletedSetup)
        self.providerId = defaults.string(forKey: Keys.selectedProviderId)
    }

    /// Proves the on-device embedding model can actually produce a vector — it has to
    /// download assets the first time, and on some Macs never becomes available — and falls
    /// back to `HashEmbedder` if it can't. Called once from `RootView`'s `.task`, because
    /// `Embedder.embed` is async and `init` is not.
    func warmEmbedder() async {
        guard embedder is NLContextualEmbedder else { return }
        do {
            _ = try await embedder.embed("Ties")
        } catch {
            embedder = HashEmbedder()
        }
    }

    // MARK: - Factories

    /// Builds the selected provider from its catalogue spec, saved config, Keychain key, and
    /// last detection. A CLI provider with no detection yet throws `.notInstalled` rather
    /// than shelling out to a path we never found.
    func makeProvider() throws -> any AIProvider {
        guard let id = selectedProviderId, let spec = ProviderCatalog.spec(id) else {
            throw ProviderError.unavailable("No AI provider is selected")
        }
        return try ProviderFactory.make(
            spec: spec,
            config: providerConfig(for: id),
            apiKey: Keychain.get(account: id),
            detected: detections[id] ?? .available(""),
            client: http,
            apple: { AppModel.appleProvider() }
        )
    }

    /// The full probe set, each one configured with whatever optional key the user has saved.
    /// `UsernameProbe` is skipped (rather than crashing the scan) if the bundled
    /// WhatsMyName dataset can't be read.
    func makeScanner() -> ResearchScanner {
        var probes: [any Probe] = [
            GravatarProbe(apiKey: Keychain.get(account: "gravatar")),
            GitHubProbe(token: Keychain.get(account: "github")),
            SearchProbe(backend: searchBackend),
        ]
        if let dataset = try? WMNDataset.bundled() {
            probes.append(UsernameProbe(dataset: dataset))
        }
        probes.append(PageFetchProbe())
        return ResearchScanner(store: store, probes: probes, client: http)
    }

    func makeExtractor() throws -> Extractor {
        Extractor(store: store, provider: try makeProvider(), embedder: embedder)
    }

    // MARK: - Provider detection and configuration

    /// Detects `spec` on this Mac, memoizing the result in `detections`.
    func detect(_ spec: ProviderSpec) async -> DetectResult {
        if let cached = detections[spec.id] { return cached }
        let detector = ProviderDetector(
            client: http,
            appleAvailable: { AppModel.appleIntelligenceAvailable }
        )
        let result = await detector.detect(spec)
        detections[spec.id] = result
        return result
    }

    /// The user's base URL/model/header overrides for one provider, stored as JSON under
    /// `providerConfig.<id>`.
    func providerConfig(for id: String) -> ProviderConfig? {
        guard let data = defaults.data(forKey: Keys.providerConfigPrefix + id) else { return nil }
        return try? JSONDecoder().decode(ProviderConfig.self, from: data)
    }

    func setProviderConfig(_ config: ProviderConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: Keys.providerConfigPrefix + config.id)
    }

    // MARK: - Apple Intelligence

    /// `FoundationModels` only exists in the app target and only on macOS 26, so TiesCore
    /// takes the provider as a closure and this is what it calls.
    nonisolated static func appleProvider() -> (any AIProvider)? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), AppleFoundationProvider.isAvailable {
            return AppleFoundationProvider()
        }
        #endif
        return nil
    }

    nonisolated static var appleIntelligenceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return AppleFoundationProvider.isAvailable }
        #endif
        return false
    }

    // MARK: - Search backend

    /// DuckDuckGo via an off-screen web view unless the user picked an API-key backend and
    /// actually has a key for it.
    private static func makeSearchBackend(defaults: UserDefaults, client: any HTTPClient) -> any SearchBackend {
        switch defaults.string(forKey: Keys.searchBackend) {
        case "tavily":
            if let key = Keychain.get(account: "tavily"), !key.isEmpty {
                return TavilySearchBackend(apiKey: key, client: client)
            }
        case "exa":
            if let key = Keychain.get(account: "exa"), !key.isEmpty {
                return ExaSearchBackend(apiKey: key, client: client)
            }
        default:
            break
        }
        return WebKitSearchBackend()
    }
}
