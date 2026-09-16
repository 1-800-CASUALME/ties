import AppKit
import SwiftUI
import TiesCore

/// The Settings scene: where the database lives and what to do with it, which AI reads the
/// pages, and which search engine finds them.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ProviderSettingsView()
                .tabItem { Label("Providers", systemImage: "sparkles") }
            ResearchSettingsView()
                .tabItem { Label("Research", systemImage: "magnifyingglass") }
        }
        .frame(width: 600, height: 480)
    }
}

// MARK: - General

/// The database itself: where it is, how big it has got, and the two ways out of it — a JSON
/// copy of everything, or nothing at all.
private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var confirmingDelete = false
    @State private var message: String?
    @State private var updateStatus: UpdateStatus?
    @State private var checking = false
    @State private var exporting = false
    /// Read on appear and after anything that changes it, rather than per body pass: it stats a
    /// file, and `body` runs on every keystroke anywhere in this window.
    @State private var databaseSize: Int64 = 0

    private var databaseURL: URL { Store.defaultURL }

    var body: some View {
        Form {
            Section("Database") {
                LabeledContent("Location") {
                    HStack(spacing: 8) {
                        Text(databaseURL.path)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([databaseURL])
                        }
                    }
                }
                LabeledContent("Size", value: formattedSize)
            }

            Section {
                HStack(spacing: 10) {
                    Button("Export JSON…", action: exportJSON)
                        .disabled(exporting)
                    if exporting {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Button("Delete Everything", role: .destructive) { confirmingDelete = true }
                        .disabled(exporting)
                }
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Exporting writes every person, their contact details, profile, and note to one file. Deleting empties the database, throws away the cached pages and the saved keys, and starts setup again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                HStack(spacing: 10) {
                    Button("Check for Updates…", action: checkForUpdates)
                        .disabled(checking)
                    if checking {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Text("Version \(UpdateChecker.currentVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let updateStatus {
                    updateLine(updateStatus)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshSize)
        .confirmationDialog("Delete everything?", isPresented: $confirmingDelete) {
            Button("Delete Everything", role: .destructive, action: deleteEverything)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every person, profile, note, researched page, cached download and saved API key is removed from this Mac. This can't be undone.")
        }
    }

    @ViewBuilder
    private func updateLine(_ status: UpdateStatus) -> some View {
        switch status {
        case .upToDate:
            Label("Ties is up to date.", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .available(let tag, let url):
            HStack(spacing: 8) {
                Label("\(tag) is available.", systemImage: "arrow.down.circle")
                    .font(.callout)
                Link("Open the release page", destination: url)
                    .font(.callout)
            }
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: databaseSize, countStyle: .file)
    }

    private func refreshSize() {
        databaseSize = model.store.databaseSizeBytes()
    }

    /// Serializes every person and writes the file off the main actor: the export walks the
    /// whole database and encodes it, which on a large one is long enough to freeze the window
    /// if it happens where the window is drawn.
    private func exportJSON() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Ties.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        exporting = true
        message = nil
        let store = model.store
        Task {
            message = await Task.detached {
                do {
                    try store.exportJSON().write(to: url)
                    return "Exported to \(url.lastPathComponent)."
                } catch {
                    return error.localizedDescription
                }
            }.value
            exporting = false
            refreshSize()
        }
    }

    /// Erases the database, the Keychain items, the page cache and the settings, and drops the
    /// app back into setup — with nothing left, the main window has nothing to show and the
    /// wizard is the only sensible screen. `AppModel.deleteEverything()` does the work, and
    /// stops anything still running before it starts.
    ///
    /// The size row is re-read afterwards: the database has been vacuumed, and a Size that still
    /// reported the old file would say the deletion hadn't happened.
    private func deleteEverything() {
        do {
            try model.deleteEverything()
            message = "Everything deleted."
            refreshSize()
        } catch {
            message = error.localizedDescription
        }
    }

    private func checkForUpdates() {
        checking = true
        updateStatus = nil
        Task {
            updateStatus = await UpdateChecker.check()
            checking = false
        }
    }
}

// MARK: - Providers

/// The same catalogue grid and key fields setup uses, plus the way back into setup for contacts
/// that weren't picked the first time.
private struct ProviderSettingsView: View {
    @Environment(AppModel.self) private var model

    private var selectedSpec: ProviderSpec? {
        model.selectedProviderId.flatMap(ProviderCatalog.spec)
    }

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                ProviderGrid(
                    detections: model.detections,
                    selectedId: model.selectedProviderId,
                    onSelect: { model.selectedProviderId = $0 }
                )
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)

            if let selectedSpec {
                ProviderFields(spec: selectedSpec)
            }

            Divider()

            HStack {
                Button("Add more contacts…") { model.addMoreContacts() }
                Spacer()
            }
        }
        .padding(20)
        .task { await detectAll() }
    }

    /// Probes every catalogue entry at once rather than in sequence: the slowest rules shell out
    /// or wait on a local HTTP timeout, and run one after another they would add up to most of a
    /// minute. `AppModel.detect` writes each result into `detections` as it lands, so dots
    /// appear progressively and a second visit to this tab re-reads rather than re-probes.
    private func detectAll() async {
        await withTaskGroup(of: Void.self) { group in
            for spec in ProviderCatalog.all {
                group.addTask { [model] in _ = await model.detect(spec) }
            }
        }
    }
}

// MARK: - Research

/// Which engine the research searches with, and the optional keys that make the probes better.
private struct ResearchSettingsView: View {
    @AppStorage("searchBackend") private var searchBackend = "duckduckgo"

    var body: some View {
        Form {
            Section {
                Picker("Search with", selection: $searchBackend) {
                    Text("DuckDuckGo").tag("duckduckgo")
                    Text("Tavily").tag("tavily")
                    Text("Exa").tag("exa")
                }
                if searchBackend == "tavily" {
                    KeyField(title: "Tavily key", account: "tavily")
                }
                if searchBackend == "exa" {
                    KeyField(title: "Exa key", account: "exa")
                }
            } footer: {
                Text("DuckDuckGo needs no key and is used whenever the chosen engine has none. Changing the engine takes effect the next time Ties starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                KeyField(title: "Gravatar key", account: "gravatar")
                KeyField(title: "GitHub token", account: "github")
            } header: {
                Text("Optional keys")
            } footer: {
                Text("Both probes work without a key; a key only raises the rate limit they run into.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// One Keychain-backed secret. Written through as it is typed, and removed when emptied, so
/// there is nothing to save and no way to leave a stale key behind.
private struct KeyField: View {
    let title: String
    let account: String

    @State private var value = ""

    var body: some View {
        SecureField(title, text: $value)
            .onChange(of: account, initial: true) { value = Keychain.get(account: account) ?? "" }
            .onChange(of: value) { _, key in
                if key.isEmpty {
                    Keychain.delete(account: account)
                } else {
                    try? Keychain.set(key, account: account)
                }
            }
    }
}
