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
                        .disabled(exporting || model.storeFailure != nil)
                    if exporting {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    // With the real database unopenable these would only act on the in-memory
                    // placeholder while every row on disk survived.
                    Button("Delete Everything", role: .destructive) { confirmingDelete = true }
                        .disabled(exporting || model.storeFailure != nil)
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
                privacyRow(selectedSpec)
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

    /// The privacy switch (§7.5), next to the provider it is about. Off, a cloud provider gets
    /// public snippets and Contacts-level facts only; the judge, the expansion and the drafting
    /// run without the signals this Mac collected, and a draft gets no register sample.
    ///
    /// The lock says what the switch means for *this* provider: Apple Intelligence runs on this
    /// Mac, so nothing leaves it whatever the switch says, and the lock is open because the
    /// signals are in fact available to it.
    private func privacyRow(_ spec: ProviderSpec) -> some View {
        let open = model.shareSignals || spec.tier == .onDevice
        let explanation = spec.tier == .onDevice
            ? "\(spec.name) runs on this Mac, so your signals never leave it."
            : open
                ? "Aliases, titles, companies and honorifics are sent to \(spec.name). Never a message, a subject line, or your address book."
                : "\(spec.name) sees public snippets and Contacts details only."

        return HStack(spacing: 10) {
            Image(systemName: open ? "lock.open" : "lock")
                .foregroundStyle(open ? .secondary : Color.accentColor)
                .help(explanation)
                .accessibilityLabel(explanation)

            Toggle("Let cloud AI see local signals", isOn: shareSignals)
                .toggleStyle(.switch)
                .help(explanation)

            Spacer(minLength: 0)
        }
        .animation(.snappy, value: open)
    }

    private var shareSignals: Binding<Bool> {
        Binding(
            get: { model.shareSignals },
            set: { model.shareSignals = $0 }
        )
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

/// Which engine the research searches with, how deep it digs, and the optional keys that make
/// the probes better.
private struct ResearchSettingsView: View {
    @Environment(AppModel.self) private var model

    /// The engine the user has picked here that has no key yet, which the sheet is asking for.
    @State private var askingKeyFor: SearchBackendChoice?

    /// Reads the saved engine, and on a change takes the same path the Scan screen's menu
    /// takes: an engine with no key is asked for one first, rather than being saved as the
    /// choice while the research quietly carries on with DuckDuckGo underneath it.
    private var backend: Binding<String> {
        Binding(
            get: { model.searchBackendId },
            set: { choose($0) }
        )
    }

    private func choose(_ id: String) {
        // Re-picking the engine already running is the only no-op; re-picking the saved one
        // while something else is actually searching is how a fallback gets put right.
        guard id != model.searchBackendId || id != model.activeSearchBackendId else { return }
        let choice = SearchBackendChoice.named(id)
        guard choice.hasKey else {
            askingKeyFor = choice
            return
        }
        model.setSearchBackend(id)
    }

    private var mode: Binding<ScanMode> {
        Binding(
            get: { model.scanMode },
            set: { model.setScanMode($0) }
        )
    }

    /// How many hidden web views the web search runs at once. Rebuilding the pool throws away
    /// its web views, so this is written through on each step rather than on some later commit
    /// — a stepper has no "done", and the next scan is what reads it.
    private var poolSize: Binding<Int> {
        Binding(
            get: { model.searchPoolSize },
            set: { model.setSearchPoolSize($0) }
        )
    }

    var body: some View {
        Form {
            Section {
                SearchBackendPicker(backend: backend) { _ in
                    // A key finished after the engine was chosen: rebuild around it, or the
                    // engine would be selected and still searching with DuckDuckGo underneath.
                    // A key that was just cleared rebuilds too — falling back is then the
                    // honest thing for the backend to do, and the menu says so.
                    model.setSearchBackend(model.searchBackendId)
                }
                ScanModePicker(mode: mode)
                Stepper(value: poolSize, in: 1...AppModel.maxPoolSize) {
                    Label {
                        Text(model.searchPoolSize == 1
                            ? "One web search at a time"
                            : "\(model.searchPoolSize) web searches at once")
                    } icon: {
                        Image(systemName: "square.grid.2x2")
                    }
                }
                .help("Parallel web searches")
            } footer: {
                Text("DuckDuckGo needs no key and is used whenever the chosen engine has none; it runs in hidden web views, and more of them means more people researched at once. Quick runs one or two searches, fifteen username sites and three pages for each person; thorough runs four searches, forty sites and every page. All three take effect on the next research run.")
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
        .sheet(item: $askingKeyFor) { choice in
            SearchBackendKeySheet(choice: choice) { useIt in
                askingKeyFor = nil
                if useIt { model.setSearchBackend(choice.id) }
            }
        }
    }
}
