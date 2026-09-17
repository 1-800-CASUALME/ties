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
    static let configKey = "lookup.customConfig"
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

    static func customConfig(_ defaults: UserDefaults = .standard) -> CustomLookupConfig {
        guard let data = defaults.data(forKey: configKey),
              let config = try? JSONDecoder().decode(CustomLookupConfig.self, from: data)
        else { return CustomLookupConfig() }
        return config
    }

    static func setCustomConfig(_ config: CustomLookupConfig, _ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: configKey)
    }

    /// The chosen service, ready to call, or `nil` when nothing is set up. Reading the Keychain
    /// here rather than holding the key in memory keeps it out of the model — and out of a crash
    /// report.
    static func makeProvider(client: any HTTPClient, defaults: UserDefaults = .standard) -> (any LookupProvider)? {
        guard let id = selectedId(defaults) else { return nil }
        let secret = Keychain.get(account: LookupCatalog.secretAccount(id))

        switch id {
        case LookupCatalog.twilioId:
            guard let sid = Keychain.get(account: LookupCatalog.identifierAccount(id)), !sid.isEmpty,
                  let token = secret, !token.isEmpty
            else { return nil }
            return TwilioLookupProvider(accountSID: sid, authToken: token, client: client)
        case LookupCatalog.customId:
            let config = customConfig(defaults)
            guard config.isUsable else { return nil }
            return CustomLookupProvider(config: config, key: secret, client: client)
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
        for key in [providerKey, configKey, budgetKey] {
            defaults.removeObject(forKey: key)
        }
    }
}
