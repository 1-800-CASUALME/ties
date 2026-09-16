import SwiftUI

/// The first-run setup shell: one screen at a time, pushed left or right, over a bottom bar
/// with the step dots and a Back button.
struct WizardWindow: View {
    @State private var state = WizardState()

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
        default:
            // Replaced screen by screen in the tasks that follow.
            Text(String(describing: state.step))
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }

    private var bottomBar: some View {
        ZStack {
            StepDots(count: WizardStep.allCases.count, current: state.step.rawValue)
            HStack {
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

    /// No way back out of the first screen, and none out of a step that is already doing
    /// work or has finished it.
    private var showsBack: Bool {
        switch state.step {
        case .welcome, .scan, .extract, .done: false
        default: true
        }
    }
}
