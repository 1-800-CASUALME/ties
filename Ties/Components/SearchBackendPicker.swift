import SwiftUI
import TiesCore

/// One search engine as the UI knows it: the id stored in `UserDefaults`, the name shown for it,
/// and the Keychain account its API key lives under — `nil` for the one that needs no key.
struct SearchBackendChoice: Identifiable, Hashable {
    let id: String
    let name: String
    let keyAccount: String?

    /// The three engines, in the order they are offered.
    static let all = [
        SearchBackendChoice(id: "duckduckgo", name: "DuckDuckGo", keyAccount: nil),
        SearchBackendChoice(id: "tavily", name: "Tavily", keyAccount: "tavily"),
        SearchBackendChoice(id: "exa", name: "Exa", keyAccount: "exa"),
    ]

    /// Falls back to DuckDuckGo, which is also what `AppModel` builds for an unknown id.
    static func named(_ id: String?) -> SearchBackendChoice {
        all.first { $0.id == id } ?? all[0]
    }

    /// Whether this engine could actually run right now: DuckDuckGo always can, the other two
    /// only with a key saved for them.
    var hasKey: Bool {
        guard let keyAccount else { return true }
        return !(Keychain.get(account: keyAccount) ?? "").isEmpty
    }
}

/// The engine picker and the key field the chosen engine needs, which Settings' Research tab and
/// the Scan screen's sheet both show.
struct SearchBackendPicker: View {
    @Binding var backend: String
    /// Called once the key for the current engine has been committed — Return, or the field
    /// losing focus — so whoever is showing this can rebuild the backend around it. Not per
    /// keystroke: rebuilding the backend throws away a web view, and doing that for every
    /// character of a pasted key is work nobody asked for.
    var onKeyCommitted: (String) -> Void = { _ in }

    var body: some View {
        Picker("Search with", selection: $backend) {
            ForEach(SearchBackendChoice.all) { choice in
                Text(choice.name).tag(choice.id)
            }
        }
        if let account = SearchBackendChoice.named(backend).keyAccount {
            KeyField(
                title: "\(SearchBackendChoice.named(backend).name) key",
                account: account,
                onCommit: onKeyCommitted
            )
        }
    }
}

/// Asks for the key an engine needs, at the moment the user picks it — a scan that switched to
/// Tavily and quietly carried on with DuckDuckGo because there was no key would look like the
/// switch had simply done nothing.
struct SearchBackendKeySheet: View {
    let choice: SearchBackendChoice
    /// `true` once a key is in the Keychain and the user wants to go ahead with this engine.
    let onFinish: (Bool) -> Void

    @State private var hasKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("\(choice.name) needs a key", systemImage: "key")
                .font(.headline)
            Text("Paste your \(choice.name) API key. It is kept in this Mac's Keychain and is only ever sent to \(choice.name).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let account = choice.keyAccount {
                KeyField(title: "\(choice.name) key", account: account, onChange: { key in
                    hasKey = !key.isEmpty
                })
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onFinish(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Use \(choice.name)") { onFinish(true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasKey)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { hasKey = choice.hasKey }
    }
}

/// One Keychain-backed secret. Written through as it is typed, and removed when emptied, so
/// there is nothing to save and no way to leave a stale key behind.
///
/// Two callbacks, because the two things watching a key field want different moments: whether
/// there is a key yet (per keystroke) and whether the user has finished typing one (Return, or
/// focus leaving the field). Anything that rebuilds itself around the key wants the second.
struct KeyField: View {
    let title: String
    let account: String
    /// Every change to the key as it is typed or cleared. Cheap reactions only.
    var onChange: (String) -> Void = { _ in }
    /// The key as it stands once the user has finished with the field.
    var onCommit: (String) -> Void = { _ in }

    @State private var value = ""
    @FocusState private var focused: Bool

    var body: some View {
        SecureField(title, text: $value)
            .focused($focused)
            .onSubmit { onCommit(value) }
            .onChange(of: focused) { wasFocused, isFocused in
                if wasFocused, !isFocused { onCommit(value) }
            }
            .onChange(of: account, initial: true) { value = Keychain.get(account: account) ?? "" }
            .onChange(of: value) { _, key in
                // The field filling itself in from the Keychain is not a change the user made,
                // and reporting it as one is what had Settings rebuilding the search backend
                // every time its tab appeared.
                guard key != (Keychain.get(account: account) ?? "") else { return }
                if key.isEmpty {
                    Keychain.delete(account: account)
                } else {
                    try? Keychain.set(key, account: account)
                }
                onChange(key)
            }
    }
}
