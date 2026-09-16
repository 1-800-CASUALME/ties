import SwiftUI

/// The first-run setup shell: one screen at a time, pushed left or right, over a bottom bar
/// with the step dots and a Back button.
struct WizardWindow: View {
    @Environment(AppModel.self) private var model
    @State private var state: WizardState

    /// Whether this trip through setup can be abandoned. False on a first run — there is no app
    /// behind the wizard to go back to — and true when Settings' "Add more contacts…" reopened
    /// it over a database that is already set up, where finishing the whole thing again is not
    /// something the user should be forced into.
    private let canCancel: Bool

    /// Setup normally starts at the beginning. The one exception is "Add more contacts…", which
    /// reopens it at the contact picker over a database that is already full.
    init(startingAt step: WizardStep = .welcome, canCancel: Bool = false) {
        let state = WizardState()
        state.step = step
        _state = State(initialValue: state)
        self.canCancel = canCancel
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.push(from: state.direction))
                    .animation(.snappy, value: state.step)
                    .clipped()
                bottomBar
            }
        }
        .frame(width: 720, height: 520)
        .background(.regularMaterial)
        .environment(state)
    }

    @ViewBuilder
    private var content: some View {
        switch state.step {
        case .welcome:
            WelcomeView()
        case .access:
            AccessView()
        case .select:
            SelectView()
        case .provider:
            ProviderView()
        case .scan:
            ScanView()
        case .review:
            ReviewView()
        case .extract:
            ExtractView()
        case .done:
            DoneView()
        }
    }

    private var bottomBar: some View {
        ZStack {
            StepDots(count: WizardStep.allCases.count, current: state.step.rawValue)
            HStack(spacing: 4) {
                if canCancel {
                    Button(action: cancel) {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel setup")
                    .help("Cancel and go back to Ties")
                }
                Button { state.back() } label: {
                    Image(systemName: "chevron.backward")
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
                .accessibilityLabel("Back")
                .help("Back")
                .opacity(showsBack ? 1 : 0)
                .disabled(!showsBack)
                .animation(.snappy, value: showsBack)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// Leaves setup for the app, on any step. Whatever the wizard has already written stays —
    /// the contacts it synced, the people it researched — because all of it is the user's data
    /// either way; only the rest of the run is abandoned.
    ///
    /// Anything still in flight is stopped first: this view and the `WizardState` holding the
    /// scanner go away with it, and a run nobody is watching would keep working through people
    /// and writing candidates long after the screen that asked for them is gone.
    private func cancel() {
        let scanner = state.scanner
        let extractor = state.extractor
        state.scanner = nil
        state.extractor = nil
        Task {
            await scanner?.cancel()
            await extractor?.cancel()
        }
        model.resumeWizardStep = nil
        model.hasCompletedSetup = true
    }

    /// No way back out of the first screen, and none out of a step that is already doing
    /// work or has finished it. Review is in that company: the research behind it has already
    /// run, and the screen has its own per-person re-run for anything that needs another look.
    private var showsBack: Bool {
        switch state.step {
        case .welcome, .scan, .review, .extract, .done: false
        default: true
        }
    }
}
