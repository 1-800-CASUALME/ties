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
    /// The disk cache `http` reads and writes. Held here as well so "Delete Everything" can
    /// empty the one the app is actually using rather than a second handle on the same folder.
    let cache: DiskCache
    let contacts = ContactsService()
    let searchBackend: any SearchBackend

    /// Why the database on disk couldn't be opened, if it couldn't. `nil` in every normal case
    /// — including the one where an unopenable file was moved aside and a fresh one opened in
    /// its place. When it is set, `store` is a throwaway in-memory database that nothing reads
    /// and `RootView` shows the recovery screen instead of any of the app.
    let storeFailure: String?

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

    /// Who the main window has selected, so menu commands — which have no view of their own —
    /// know whether "Refresh Selected" has anything to act on.
    var selectedPersonId: String?

    /// Menu commands act on the main window, which owns the sheets and the refresh. Each of
    /// these is bumped by the command and watched by the window; a counter rather than a flag
    /// so pressing the same command twice in a row lands twice.
    var newPersonRequest = 0
    var refreshRequest = 0

    /// Where the setup wizard should open when it is shown again. `nil` starts it from the
    /// beginning, which is what a first run (or a wiped database) wants; Settings' "Add more
    /// contacts…" sets it to `.access` so the wizard reopens at the Contacts step instead.
    /// Deliberately not persisted: it describes one trip through setup, not a preference.
    var resumeWizardStep: WizardStep?

    /// Long-running work a view has started — a refresh, a search — kept so something that
    /// pulls the ground out from under all of it can stop it first. Not observed: registering
    /// a task is bookkeeping, not a change any view draws.
    @ObservationIgnored private var work: [UUID: Task<Void, Never>] = [:]

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
        let opened = AppModel.openStore()
        let cache = DiskCache(directory: DiskCache.defaultDirectory)
        let http = URLSessionHTTPClient(cache: cache)
        let embedder = NLContextualEmbedder()

        self.defaults = defaults
        self.store = opened.store
        self.storeFailure = opened.failure
        self.http = http
        self.cache = cache
        self.embedder = embedder
        self.searchBackend = AppModel.makeSearchBackend(defaults: defaults, client: http)
        self.setupCompleted = defaults.bool(forKey: Keys.hasCompletedSetup)
        self.providerId = defaults.string(forKey: Keys.selectedProviderId)
    }

    // MARK: - Opening the database

    /// Opens the database — `Store.open` creates the Application Support directory itself, so a
    /// first run has nothing to prepare — and, if it won't open, tries once to get out of the
    /// way of whatever is wrong with it: the file is renamed `ties.sqlite.broken-<timestamp>`
    /// (with its `-wal`/`-shm` siblings, which belong to it) and a fresh one opened in its
    /// place. Nothing is deleted; a file that can still be handed to `sqlite3` is worth more
    /// than a tidy folder.
    ///
    /// If that fails too, the app gets an in-memory database to stand in for the one it hasn't
    /// got, and a message for `RootView` to show. This used to be a `fatalError`: a corrupt
    /// file, a failed migration or a full disk meant a crash on every launch, with nothing said
    /// and no way to reach Settings.
    private static func openStore() -> (store: Store, failure: String?) {
        let url = Store.defaultURL
        do {
            return (try Store.open(at: url), nil)
        } catch {
            let firstError = error
            do {
                try moveDatabaseAside(url)
                return (try Store.open(at: url), nil)
            } catch {
                let failure = """
                    Ties couldn't open \(url.path), and couldn't move it aside to start over.

                    \(firstError.localizedDescription)
                    """
                return (placeholderStore(), failure)
            }
        }
    }

    /// Renames the database and the two files SQLite keeps beside it out of the way, so the
    /// next `Store.open` makes a new one. A `-wal` left next to a fresh database would be read
    /// as part of it, so all three move together or the whole attempt is abandoned.
    private static func moveDatabaseAside(_ url: URL) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = ".broken-" + formatter.string(from: .now)

        let manager = FileManager.default
        for sibling in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + sibling)
            guard manager.fileExists(atPath: source.path) else { continue }
            try manager.moveItem(at: source, to: URL(fileURLWithPath: source.path + suffix))
        }
    }

    /// Stands in for the database when there is none, so the rest of the object graph — every
    /// view of which holds a `Store` — can still be built and can still draw the recovery
    /// screen. Nothing is ever written to it or read back out.
    private static func placeholderStore() -> Store {
        do {
            return try Store.inMemory()
        } catch {
            // Migrating an empty in-memory database can only fail if the schema itself is
            // wrong, which is a bug in this build rather than anything on the user's Mac.
            preconditionFailure("Ties could not create an in-memory database: \(error)")
        }
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

    /// Re-enters setup at the Contacts step, keeping everything already researched. It starts
    /// there rather than at the picker because "more contacts" usually means people added to
    /// the address book since the first run: `AccessView` re-reads the authorization status and
    /// syncs again on Continue, so those arrive in the store before the picker lists them.
    func addMoreContacts() {
        resumeWizardStep = .access
        hasCompletedSetup = false
    }

    // MARK: - Background work

    /// Runs `operation` as a tracked task: it is cancelled along with everything else by
    /// `cancelAllWork()`, and forgotten by itself once it finishes. The returned task is the
    /// caller's to cancel on its own account (a view leaving the screen, a newer query
    /// replacing an older one).
    @discardableResult
    func track(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let token = UUID()
        let task = Task { @MainActor in
            await operation()
            self.work[token] = nil
        }
        // The task can't have run yet — it is `@MainActor` and so are we — so this can never
        // re-add one that has already finished and removed itself.
        work[token] = task
        return task
    }

    /// Stops every tracked task. Called before the database is emptied: a scan or a search that
    /// outlives the rows it was reading would write results about people who no longer exist.
    func cancelAllWork() {
        let running = Array(work.values)
        work.removeAll()
        for task in running {
            task.cancel()
        }
    }

    // MARK: - Erasing everything

    /// Removes everything Ties has put on this Mac: every row in the database (vacuumed, so the
    /// pages it frees don't keep the names and page bodies that were written on them), every
    /// Keychain item, the cached body of every page the research fetched, and the settings
    /// describing the setup that produced all of it. Exactly what the confirmation dialog in
    /// Settings promises, so that promise is true.
    ///
    /// Work still running is stopped first. A scan or a search started before this point is
    /// reading rows that are about to go, and would otherwise finish by writing candidates,
    /// profiles, or a note about people who no longer exist.
    ///
    /// The open database and the search backend themselves are left alone: both were built at
    /// launch, and the app is on its way back to setup, which builds what it needs again.
    func deleteEverything() throws {
        cancelAllWork()

        // Everything that can't fail goes first, so a database error can't leave the API keys
        // and the cached pages behind — they are the part of this the user has no other way to
        // reach, and the part the dialog is most explicit about.
        Keychain.deleteAll()
        cache.clear()
        clearSettings()

        try store.deleteEverything()
    }

    /// Forgets the chosen provider, its saved overrides, the search engine, and the fact that
    /// setup was ever finished — which drops the app back into the wizard, the only screen with
    /// anything to show once the database is empty.
    private func clearSettings() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Keys.providerConfigPrefix) {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: Keys.selectedProviderId)
        defaults.removeObject(forKey: Keys.searchBackend)
        defaults.removeObject(forKey: Keys.hasCompletedSetup)

        providerId = nil
        setupCompleted = false
        detections = [:]
        selectedPersonId = nil
        resumeWizardStep = nil
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
