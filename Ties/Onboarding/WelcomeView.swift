import AppKit
import SwiftUI

/// First screen of setup: what Ties is, in one line, and what it is about to do.
struct WelcomeView: View {
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

            PrimaryButton("Continue") { state.next() }
        }
        .padding(40)
        .onAppear {
            withAnimation(.snappy) { appeared = true }
        }
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
