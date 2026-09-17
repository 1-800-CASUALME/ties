import SwiftUI
import TiesCore

/// Settings › Sources: the same four rows as the wizard's Sources step, plus the way to read
/// them all again once something has changed — a Mac that has just been given Full Disk Access,
/// a WhatsApp that has just been installed, or simply a year of new conversations (spec §6).
struct SourcesSettingsView: View {
    @Environment(AppModel.self) private var model

    /// How often the rows re-check themselves while this pane is open.
    private static let recheckInterval = Duration.seconds(3)

    @State private var progress: ScanProgress?
    @State private var message: String?

    private var sources: SourcesModel { model.sources }

    var body: some View {
        Form {
            Section {
                ForEach(SourcesModel.all) { source in
                    SourceRow(
                        source: source,
                        icon: sources.icon(for: source),
                        status: sources.statuses[source.id] ?? .ready,
                        enabled: binding(for: source)
                    )
                }
            } footer: {
                Text("Everything here is read on this Mac, in a copy, and never written back or sent anywhere. Messages, WhatsApp and Mail need Full Disk Access; Contacts is whatever the address book already gave.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 10) {
                    Button(action: collectAgain) {
                        Label("Collect again", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.settingsCollector != nil || model.storeFailure != nil)
                    .help("Read every source again for everyone")

                    if let progress, model.settingsCollector != nil {
                        pill(progress)
                    }

                    Spacer()

                    if sources.needsAccess {
                        Button { sources.openPrivacySettings() } label: {
                            Label("Open Privacy Settings", systemImage: "lock.open")
                        }
                        .help("Open Full Disk Access in System Settings")
                    }
                }
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(sources.needsAccess
                    ? "Add Ties in Full Disk Access, then come back."
                    : "A fresh pass reads each source from the beginning and replaces what the last one found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .animation(.snappy, value: sources.needsAccess)
        .task { await recheckWhileVisible() }
        // The run outlives this pane's `@State`, not the app: closing Settings mid-collection
        // stops it rather than leaving it reading sources for a screen nobody can see.
        .onDisappear { model.cancelSettingsCollection() }
    }

    /// How far the run has got, small enough to sit beside the button that started it.
    private func pill(_ progress: ScanProgress) -> some View {
        HStack(spacing: 6) {
            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                .frame(width: 70)
            Text("\(progress.completed) of \(progress.total)")
                .font(.caption)
                .monospacedDigit()
            Button { stop() } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Stop")
            .help("Stop collecting")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .transition(.opacity)
    }

    private func binding(for source: SourcesModel.Source) -> Binding<Bool> {
        Binding(
            get: { model.sources.isEnabled(source.id) },
            set: { model.sources.setEnabled(source.id, $0) }
        )
    }

    // MARK: - Collecting again

    /// Reads every enabled, ready source for everyone in the database. Tracked by `AppModel`, so
    /// "Delete Everything" stops it before it can write signals about people who have just gone.
    private func collectAgain() {
        guard model.settingsCollector == nil else { return }
        message = nil
        model.track {
            do {
                let ids = try model.store.allPeople().map(\.id)
                guard !ids.isEmpty else {
                    message = "There is nobody to collect for yet."
                    return
                }

                // Statuses may be stale by a few seconds, and a run built on a stale one would
                // include a source that has since been locked and fail against every person.
                await model.sources.refresh()

                let collector = model.makeSignalCollector()
                model.settingsCollector = collector
                withAnimation(.snappy) { progress = ScanProgress(completed: 0, total: ids.count) }

                for await update in await collector.run(personIds: ids) {
                    progress = update
                }

                let read = progress?.completed ?? 0
                finish(collector)
                message = "Read your sources for \(read) \(read == 1 ? "person" : "people")."
            } catch {
                // Only the people query throws, and it throws before anything is running — but
                // the pane is put back to idle regardless rather than trusting that to stay true.
                model.settingsCollector = nil
                withAnimation(.snappy) { progress = nil }
                message = error.localizedDescription
            }
        }
    }

    /// Stops scheduling new people; whoever is in flight finishes and the stream ends by
    /// itself, which is what then clears the collector. Deliberately not
    /// `cancelSettingsCollection()`: freeing the button before the run has actually drained
    /// would let a second "Collect again" start on top of the first.
    private func stop() {
        let collector = model.settingsCollector
        Task { await collector?.cancel() }
    }

    /// Puts the pane back to idle, but only if the run that just ended is still the one the
    /// model is holding: a collection cancelled by closing Settings finishes draining after a
    /// new one may already have been started, and must not clear that one.
    private func finish(_ collector: SignalCollector) {
        if model.settingsCollector === collector {
            model.settingsCollector = nil
        }
        withAnimation(.snappy) { progress = nil }
    }

    /// Checks on arrival and every few seconds after, so a grant made in System Settings while
    /// this pane is open shows up here without anything being clicked.
    private func recheckWhileVisible() async {
        while !Task.isCancelled {
            await sources.refresh()
            do {
                try await Task.sleep(for: SourcesSettingsView.recheckInterval)
            } catch {
                return
            }
        }
    }
}
