import Foundation
import TiesCore

/// Where the lookup slot's settings live, and how a provider is built out of them.
///
/// Lookup is the one source that leaves this Mac, so it is the one source that is off until the
/// user has chosen a service and given it a key: everything here answers "not set up" rather
/// than guessing a default, and `makeProvider` returns `nil` until there is something real to
/// call. The keys themselves are never in `UserDefaults` — they are in the Keychain, under
/// accounts `LookupCatalog` names.
enum LookupSettings {
    static let providerKey = "lookup.providerId"
    /// One endpoint per service, keyed by its catalogue id: picking GetContact and then Custom
    /// must not have the second quietly inherit the first one's URL.
    static let configKeyPrefix = "lookup.config."
    /// Where the single described endpoint lived before there was more than one of them.
    static let legacyConfigKey = "lookup.customConfig"
    static let budgetKey = "lookup.budget"

    /// How many numbers one pass may ask about before it stops. A lookup is billed per call and
    /// an address book is long; 250 is a few dollars at the usual rates rather than a few
    /// hundred, and the stepper in Settings moves it.
    static let defaultBudget = 250
    static let budgetRange = 25...5000

    static func selectedId(_ defaults: UserDefaults = .standard) -> String? {
        guard let id = defaults.string(forKey: providerKey), LookupCatalog.spec(id) != nil else { return nil }
        return id
    }

    static func setSelectedId(_ id: String?, _ defaults: UserDefaults = .standard) {
        if let id { defaults.set(id, forKey: providerKey) } else { defaults.removeObject(forKey: providerKey) }
    }

    static func budget(_ defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: budgetKey)
        return budgetRange.contains(stored) ? stored : defaultBudget
    }

    static func setBudget(_ value: Int, _ defaults: UserDefaults = .standard) {
        defaults.set(min(max(value, budgetRange.lowerBound), budgetRange.upperBound), forKey: budgetKey)
    }

    /// What this service has been told about its endpoint: what the user typed, or — until they
    /// have typed anything — the mapping the catalogue ships for it, which is never a URL.
    static func config(for id: String, _ defaults: UserDefaults = .standard) -> CustomLookupConfig {
        if let data = defaults.data(forKey: configKeyPrefix + id),
           let config = try? JSONDecoder().decode(CustomLookupConfig.self, from: data) {
            return config
        }
        // The 0.2.1 key, before endpoints were per service. Read once, so a URL typed then is
        // still there now.
        if id == LookupCatalog.customId,
           let data = defaults.data(forKey: legacyConfigKey),
           let config = try? JSONDecoder().decode(CustomLookupConfig.self, from: data) {
            return config
        }
        return LookupCatalog.spec(id)?.preset ?? CustomLookupConfig()
    }

    static func setConfig(_ config: CustomLookupConfig, for id: String, _ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: configKeyPrefix + id)
    }

    /// The chosen service, ready to call, or `nil` when nothing is set up. Reading the Keychain
    /// here rather than holding the key in memory keeps it out of the model — and out of a crash
    /// report.
    static func makeProvider(client: any HTTPClient, defaults: UserDefaults = .standard) -> (any LookupProvider)? {
        guard let id = selectedId(defaults) else { return nil }
        let secret = Keychain.get(account: LookupCatalog.secretAccount(id))

        guard let spec = LookupCatalog.spec(id) else { return nil }
        if spec.usesCustomEndpoint {
            let config = config(for: id, defaults)
            // No URL, nothing to call. A preset on its own is a mapping waiting for an endpoint.
            guard config.isUsable else { return nil }
            return CustomLookupProvider(id: id, config: config, key: secret, client: client)
        }

        switch id {
        case LookupCatalog.twilioId:
            guard let sid = Keychain.get(account: LookupCatalog.identifierAccount(id)), !sid.isEmpty,
                  let token = secret, !token.isEmpty
            else { return nil }
            return TwilioLookupProvider(accountSID: sid, authToken: token, client: client)
        default:
            return nil
        }
    }

    /// Whether a provider could be built right now, which is what decides the Lookup row's
    /// status. Deliberately the same question `makeProvider` answers, asked without building
    /// anything, so the row can never say ready while a pass finds nothing to call.
    static func isConfigured(_ defaults: UserDefaults = .standard) -> Bool {
        makeProvider(client: URLSessionHTTPClient(), defaults: defaults) != nil
    }

    /// Forgets the choice, the custom endpoint and the budget. The keys themselves go with
    /// `Keychain.deleteAll()`, which "Delete Everything" already calls.
    static func clear(_ defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("lookup.") {
            defaults.removeObject(forKey: key)
        }
    }
}
