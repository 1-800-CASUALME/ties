import SwiftUI
import TiesCore

/// Last screen of setup: what the run came to, in three numbers, and the two ways on from it —
/// back to Review to settle the uncertain matches, or into the app itself.
///
/// The numbers are counted once when the screen appears and animate up from zero, so the tally
/// reads as the result of the run that just finished rather than a label that was always there.
struct DoneView: View {
    @Environment(AppModel.self) private var model
    @Environment(WizardState.self) private var state

    /// People the AI wrote a profile for.
    @State private var done = 0
    /// People whose best match is still only a guess, waiting on the user to confirm it.
    @State private var unsure = 0
    /// People the scan turned up no identity for at all.
    @State private var none = 0
    @State private var appeared = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.bounce, value: appeared)

            Text("All set")
                .font(.largeTitle.bold())

            HStack(spacing: 28) {
                stat(done, "profiles", systemImage: "checkmark.circle", tint: .green)
                stat(unsure, "unsure", systemImage: "questionmark.circle", tint: .orange)
                stat(none, "nothing found", systemImage: "minus.circle", tint: .secondary)
            }

            if !model.smartLists.isEmpty {
                Label(smartListCaption, systemImage: "sparkle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("Groups the AI made from what it read. They're in the sidebar.")
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack(spacing: 12) {
                Button("Review unsure", action: reviewUnsure)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(unsure == 0)

                PrimaryButton("Start searching", action: startSearching)
            }
        }
        .padding(40)
        .animation(.snappy, value: model.smartLists)
        .onAppear(perform: load)
    }

    /// The grouping started as extraction ended, so it may well land while this screen is up —
    /// which is why the count is read from the model rather than counted once like the rest.
    private var smartListCaption: String {
        model.smartLists.count == 1 ? "1 smart list" : "\(model.smartLists.count) smart lists"
    }

    private func stat(_ value: Int, _ caption: String, systemImage: String, tint: Color) -> some View {
        Label {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value, format: .number)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .imageScale(.large)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - The tally

    /// Counts the run three ways: the extract jobs that wrote something, the people whose best
    /// candidate is still pending, and the people the scan found nothing for at all.
    private func load() {
        do {
            let jobs = try model.store.counts(kind: .extract)
            let best = try model.store.bestCandidatesByPerson()
            model.loadSmartLists()

            withAnimation(.snappy) {
                done = jobs[.done] ?? 0
                unsure = best.values.filter { $0.status == .pending }.count
                none = state.selectedIds.subtracting(best.keys).count
                appeared = true
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            appeared = true
        }
    }

    /// Into the app, and out of setup for good. `resumeWizardStep` is cleared alongside the
    /// flag because it describes the trip that has just ended: left set, the next thing to
    /// reopen the wizard would drop the user back at the Contacts step rather than the start.
    private func startSearching() {
        model.resumeWizardStep = nil
        model.hasCompletedSetup = true
    }

    /// Back to Review, three steps up the wizard rather than one, so the pills that say which
    /// matches are uncertain are in front of the user again.
    private func reviewUnsure() {
        state.direction = .leading
        withAnimation(.snappy) { state.step = .review }
    }
}
