import SwiftUI

@main
struct TiesApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1000, height: 640)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Setup until it has been done once, the app itself afterwards.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.hasCompletedSetup {
                MainWindow()
            } else {
                WizardWindow()
            }
        }
        .task { await model.warmEmbedder() }
    }
}
