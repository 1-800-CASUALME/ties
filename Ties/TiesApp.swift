import AppKit
import SwiftUI
import TiesCore

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
                    .disabled(!model.hasCompletedSetup || model.storeFailure != nil)
            }
            CommandMenu("Research") {
                Button("Refresh Selected") { model.refreshRequest += 1 }
                    .keyboardShortcut("r")
                    .disabled(model.selectedPersonId == nil)
                Button("Add More Contacts…") { model.addMoreContacts() }
                    .disabled(!model.hasCompletedSetup || model.storeFailure != nil)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Setup until it has been done once, the app itself afterwards — or, when the database
/// wouldn't open, the one screen that says so.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let storeFailure = model.storeFailure {
                DatabaseUnavailableView(message: storeFailure)
            } else if model.hasCompletedSetup {
                MainWindow()
            } else {
                WizardWindow(
                    startingAt: model.resumeWizardStep ?? .welcome,
                    canCancel: model.resumeWizardStep != nil
                )
            }
        }
        .task { await model.warmEmbedder() }
    }
}


/// Shown in place of the whole app when the database wouldn't open and couldn't be replaced.
/// Nothing in Ties works without it, so the only thing offered is the folder it lives in: from
/// there the file can be moved away or handed to someone who can look at it, and the next
/// launch starts fresh.
private struct DatabaseUnavailableView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Ties can't open its database", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Show in Finder", action: reveal)
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    /// Selects the file when there is one, and opens the folder when there isn't — a database
    /// that failed to be created leaves nothing to select.
    private func reveal() {
        let url = Store.defaultURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}
