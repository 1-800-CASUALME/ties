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
        .commands {
            // The main window owns the sheet and the refresh; these only ask for them, because
            // a menu command has no view to act on.
            CommandGroup(replacing: .newItem) {
                Button("New Person…") { model.newPersonRequest += 1 }
                    .keyboardShortcut("n")
                    .disabled(!model.hasCompletedSetup)
            }
            CommandMenu("Research") {
                Button("Refresh Selected") { model.refreshRequest += 1 }
                    .keyboardShortcut("r")
                    .disabled(model.selectedPersonId == nil)
                Button("Add More Contacts…") { model.addMoreContacts() }
                    .disabled(!model.hasCompletedSetup)
            }
        }

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
                WizardWindow(startingAt: model.resumeWizardStep ?? .welcome)
            }
        }
        .task { await model.warmEmbedder() }
    }
}
