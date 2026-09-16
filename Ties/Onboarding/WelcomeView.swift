import AppKit
import SwiftUI

/// First screen of setup: what Ties is, in one line, and what it is about to do.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(WizardState.self) private var state
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            appIcon
                .resizable()
                .frame(width: 96, height: 96)
                .scaleEffect(appeared ? 1 : 0.6)

            VStack(spacing: 8) {
                Text("Ties")
                    .font(.largeTitle.bold())
                Text("Find who you know that can help.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 32) {
                Label("Scan", systemImage: "person.2.crop.square.stack")
                Label("Research", systemImage: "magnifyingglass.circle")
                Label("Find", systemImage: "sparkle.magnifyingglass")
            }
            .font(.callout)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)

            Spacer()

            VStack(spacing: 10) {
                PrimaryButton("Continue") { state.next() }
                // Straight into the app, with nothing imported and nothing researched. The
                // main window offers setup again while the store is empty, so this is a
                // detour rather than a door closing.
                Button("Skip setup", action: skip)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                    .help("Go to Ties now and set up later")
            }
        }
        .padding(40)
        .onAppear {
            withAnimation(.snappy) { appeared = true }
        }
    }

    private func skip() {
        model.resumeWizardStep = nil
        model.hasCompletedSetup = true
    }

    /// The real app icon, so the first thing the user sees is the app itself. Falls back to a
    /// symbol on the rare occasion AppKit has no icon to hand (an unbuilt icon asset).
    private var appIcon: Image {
        if let icon = NSApp.applicationIconImage {
            Image(nsImage: icon)
        } else {
            Image(systemName: "person.2.circle.fill")
        }
    }
}
