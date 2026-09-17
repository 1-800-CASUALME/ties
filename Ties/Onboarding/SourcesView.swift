import SwiftUI
import TiesCore

/// Third screen of setup: which of this Mac's own sources Ties may read.
///
/// Nothing here blocks the wizard. Continue is always available, a source that is off simply
/// contributes nothing, and a source locked behind Full Disk Access says so and offers the one
/// place that can unlock it (spec §3, §6).
///
/// Statuses are re-checked while the step is on screen, because Full Disk Access is granted in
/// System Settings — another app, another window — and the rows have to notice by themselves when
/// the user comes back.
struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @Environment(WizardState.self) private var state

    /// How often the rows re-check themselves while this step is up.
    private static let recheckInterval = Duration.seconds(3)

    private var sources: SourcesModel { model.sources }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            Image(systemName: "tray.full")
                .font(.system(size: 52))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)

            Text("Your Mac already knows who these people are.")
                .font(.title3)
                .multilineTextAlignment(.center)

            rows

            if sources.needsAccess {
                accessPrompt
            }

            Spacer(minLength: 0)

            PrimaryButton("Continue") { state.next() }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
        .animation(.snappy, value: sources.needsAccess)
        .task { await recheckWhileVisible() }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(SourcesModel.all) { source in
                SourceRow(
                    source: source,
                    icon: sources.icon(for: source),
                    status: sources.statuses[source.id] ?? .ready,
                    enabled: binding(for: source)
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: 420)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// The one button, and the one line saying what to do with it. Both only when something the
    /// user has asked for is actually locked.
    private var accessPrompt: some View {
        VStack(spacing: 6) {
            Button { sources.openPrivacySettings() } label: {
                Label("Open Privacy Settings", systemImage: "lock.open")
            }
            .controlSize(.large)
            .help("Open Full Disk Access in System Settings")

            Text("Add Ties in Full Disk Access, then come back.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .transition(.opacity)
    }

    /// Reads and writes one row's switch through the model, which persists it as it is flipped.
    private func binding(for source: SourcesModel.Source) -> Binding<Bool> {
        Binding(
            get: { model.sources.isEnabled(source.id) },
            set: { model.sources.setEnabled(source.id, $0) }
        )
    }

    /// Checks on arrival and every few seconds after, until the step is left — `.task` cancels
    /// this the moment the screen goes, so nothing keeps opening files behind the wizard.
    private func recheckWhileVisible() async {
        while !Task.isCancelled {
            await sources.refresh()
            do {
                try await Task.sleep(for: SourcesView.recheckInterval)
            } catch {
                return
            }
        }
    }
}
