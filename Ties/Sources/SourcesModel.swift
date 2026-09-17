import AppKit
import Contacts
import Foundation
import Observation
import SwiftUI
import TiesCore

/// The four local sources Ties can read — Contacts, Messages, WhatsApp, Mail — as the app shows
/// them: which ones the user allows, where each one stands on this Mac right now, and the icon
/// and name to draw it by (spec §3, §6).
///
/// It holds the *permission* side of a source and nothing else. The reading is `TiesCore`'s: this
/// builds the collectors and asks them for their status, off the main actor, because a status is
/// decided by actually opening the file — without Full Disk Access macOS denies `stat` too, so a
/// protected store is indistinguishable from a missing one until a real open says otherwise.
@MainActor
@Observable
final class SourcesModel {
    /// One source as the UI knows it. The `id` is the collector's own `SourceCollector.id`, so
    /// the rows, the `UserDefaults` keys and `statuses` all key off the same string.
    struct Source: Identifiable, Sendable {
        let id: String
        /// The app's name, not the collector's stage wording ("your chats").
        let name: String
        /// Where the app might be installed, in the order worth looking.
        let appPaths: [String]
        /// Drawn instead of the app icon when the app isn't on this Mac.
        let fallbackSymbol: String
    }

    /// The one source that needs no grant and has no app-installed question: it is read when the
    /// user allows Contacts and kept in the database from then on.
    static let contactsId = "contacts"

    /// Every source, in the order the rows are drawn. Contacts first: it is the one that is
    /// already working, and the list reads better starting from something that is.
    static let all: [Source] = [
        Source(
            id: contactsId,
            name: "Contacts",
            appPaths: ["/System/Applications/Contacts.app"],
            fallbackSymbol: "person.crop.circle.fill"
        ),
        Source(
            id: "messages",
            name: "Messages",
            appPaths: ["/System/Applications/Messages.app"],
            fallbackSymbol: "message.fill"
        ),
        Source(
            id: "whatsapp",
            name: "WhatsApp",
            // WhatsApp is a download, so it can be installed for everyone or just for this user.
            appPaths: ["/Applications/WhatsApp.app", NSHomeDirectory() + "/Applications/WhatsApp.app"],
            fallbackSymbol: "bubble.left.and.bubble.right.fill"
        ),
        Source(
            id: "mail",
            name: "Mail",
            appPaths: ["/System/Applications/Mail.app"],
            fallbackSymbol: "envelope.fill"
        ),
    ]

    /// Full Disk Access, which is where Messages, WhatsApp and Mail are unlocked.
    static let privacySettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    private static let defaultsPrefix = "sources."

    /// Whether the user allows each source, by id. All four start on: the switch records what
    /// Ties *may* read, not what it can — a source this Mac hasn't got shows as unavailable and
    /// contributes nothing whichever way its switch is set.
    private(set) var enabled: [String: Bool]

    /// Where each source stood at the last `refresh()`. Empty until the first one, which is why
    /// the rows ask for a status rather than reading it directly.
    private(set) var statuses: [String: SourceStatus] = [:]

    /// The user's own names, for `MessagesCollector`: without them "thanks Asim" in a chat with
    /// Sara reads as Sara going by Asim. Read from the "me" card once, off the main actor, and
    /// backed by the account's full name in the meantime.
    private(set) var userNames: [String] = [NSFullUserName()]

    private let defaults: UserDefaults

    /// The me card is asked for once per launch rather than on every 3-second refresh: it is a
    /// Contacts fetch, and the user's own name does not change while the wizard is open.
    @ObservationIgnored private var readUserNames = false

    /// App icons, looked up once each. `NSWorkspace` answers for a path that isn't there with a
    /// generic document icon, so `icon(for:)` checks the file first — and the result is worth
    /// keeping, because the rows redraw on every status refresh.
    @ObservationIgnored private var icons: [String: NSImage?] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var enabled: [String: Bool] = [:]
        for source in SourcesModel.all {
            // A key that was never written means "not answered yet", which is on: the toggles
            // record what the user has turned *off*, and on a first run nothing has been.
            let key = SourcesModel.defaultsPrefix + source.id
            enabled[source.id] = defaults.object(forKey: key) as? Bool ?? true
        }
        self.enabled = enabled
    }

    // MARK: - What the user allows

    func isEnabled(_ id: String) -> Bool {
        enabled[id] ?? true
    }

    /// Saves a switch the moment it is flipped. There is no "done" on a row of toggles, and the
    /// next collection — which may be the one already running behind the wizard — is what reads it.
    func setEnabled(_ id: String, _ value: Bool) {
        enabled[id] = value
        defaults.set(value, forKey: SourcesModel.defaultsPrefix + id)
    }

    // MARK: - Where each source stands

    /// True when something the user has switched on is there but locked behind Full Disk Access
    /// — the only case the "Open Privacy Settings" button has anything to fix.
    var needsAccess: Bool {
        SourcesModel.all.contains { isEnabled($0.id) && statuses[$0.id] == .needsAccess }
    }

    /// Re-checks every source. Runs off the main actor: deciding a status opens a file, and on a
    /// Mac with a locked store that open is the slow path.
    ///
    /// Called on appearance and every few seconds while a Sources view is up, because access is
    /// granted in System Settings — in another window entirely — and the rows have to catch up by
    /// themselves when the user comes back.
    func refresh() async {
        let ids = SourcesModel.all.map(\.id)
        let wantsNames = !readUserNames
        let result = await Task.detached {
            (
                SourcesModel.statuses(of: ids, userNames: []),
                wantsNames ? SourcesModel.meCardNames() : nil
            )
        }.value

        readUserNames = true
        if let names = result.1, !names.isEmpty {
            userNames = names
        }
        guard result.0 != statuses else { return }
        withAnimation(.snappy) { statuses = result.0 }
    }

    /// The status of each id, asked of the collector that would read it.
    ///
    /// An id with no file-backed collector behind it is Contacts, which is always ready: what it
    /// contributes was read when the user granted access and is in the database here, so there is
    /// nothing left to open and nothing left to grant.
    nonisolated static func statuses(of ids: [String], userNames: [String]) -> [String: SourceStatus] {
        var result: [String: SourceStatus] = [:]
        for id in ids {
            result[id] = fileCollector(id, userNames: userNames)?.status() ?? .ready
        }
        return result
    }

    /// The collector for one file-backed source. Contacts is not here: it reads back what the
    /// address book already wrote into the database, so it needs the store and `AppModel` builds it.
    nonisolated static func fileCollector(_ id: String, userNames: [String]) -> (any SourceCollector)? {
        switch id {
        case "messages": return MessagesCollector(userNames: userNames)
        case "whatsapp": return WhatsAppCollector()
        case "mail": return MailCollector()
        default: return nil
        }
    }

    // MARK: - The user's own names

    /// The names on the "me" card, most complete first, with the account's full name behind them.
    /// A Mac with no me card — or one where Contacts refuses the keys — still gets an answer,
    /// because the one thing worse than a partial list here is an empty one.
    nonisolated static func meCardNames() -> [String] {
        var names: [String] = []
        do {
            let me = try CNContactStore().unifiedMeContactWithKeys(toFetch: [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactNicknameKey as CNKeyDescriptor,
            ])
            names = [
                [me.givenName, me.familyName].filter { !$0.isEmpty }.joined(separator: " "),
                me.givenName,
                me.nickname,
            ]
        } catch {
            // No me card, or Contacts hasn't been granted: the account name stands in for it.
        }
        names.append(NSFullUserName())

        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: - How a source looks

    /// The installed app's own icon, or `nil` when the app isn't here and the row should fall
    /// back to its SF Symbol.
    func icon(for source: Source) -> NSImage? {
        if let cached = icons[source.id] { return cached }
        let image = SourcesModel.appIcon(paths: source.appPaths)
        icons[source.id] = image
        return image
    }

    private static func appIcon(paths: [String]) -> NSImage? {
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }

    /// Opens Full Disk Access in System Settings, which is the only place a Mac can be told to
    /// let Ties read Messages, WhatsApp and Mail.
    func openPrivacySettings() {
        guard let url = URL(string: SourcesModel.privacySettingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Shows the running copy of Ties in Finder, so the one dragged into Full Disk Access is the
    /// one that is actually running. macOS grants access to a particular copy of an app: a build
    /// sitting in a developer folder and a copy in Applications are two different apps to it.
    func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// Where this copy of Ties is running from, shortened for display. Worth showing when access
    /// is refused: it is usually the answer to "but I did grant it".
    var appLocation: String {
        let path = Bundle.main.bundleURL.path
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
