import AppKit
import SwiftUI
import TiesCore
import UniformTypeIdentifiers

/// Second screen of setup: ask for Contacts access, or take a vCard instead if the user has
/// already said no.
struct AccessView: View {
    @Environment(AppModel.self) private var model
    @Environment(WizardState.self) private var state
    @State private var errorMessage: String?
    @State private var working = false

    /// True once the address book is open to us, or a `.vcf` has supplied contacts instead.
    private var granted: Bool { state.access == .authorized || !state.imported.isEmpty }
    private var denied: Bool { state.access == .denied && state.imported.isEmpty }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 64))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(granted ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                .symbolEffect(.bounce, value: granted)

            Text("Ties reads your contacts to build profiles you can search.")
                .font(.title3)
                .multilineTextAlignment(.center)

            if granted {
                Label("\(state.contactCount) contacts", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            if denied {
                VStack(spacing: 12) {
                    Text("Access is off. Turn it on in System Settings, or bring in a vCard exported from Contacts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button("Open System Settings", action: openSystemSettings)
                        Button("Import .vcf…", action: importVCard)
                    }
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            Spacer()

            PrimaryButton(granted ? "Continue" : "Grant Access") {
                if granted { syncAndContinue() } else { requestAccess() }
            }
            .disabled(working)
            .overlay(alignment: .trailing) {
                if working {
                    ProgressView()
                        .controlSize(.small)
                        .offset(x: 28)
                }
            }
        }
        .padding(40)
        .animation(.snappy, value: granted)
        .animation(.snappy, value: denied)
    }

    private func requestAccess() {
        working = true
        errorMessage = nil
        Task {
            let access = await model.contacts.requestAccess()
            state.access = access
            if access == .authorized {
                do {
                    state.imported = try await model.contacts.fetchAll()
                    state.contactCount = state.imported.count
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            working = false
        }
    }

    /// Writes the imported contacts into the store before moving on, so every later screen
    /// works from `Person` rows rather than the import.
    private func syncAndContinue() {
        do {
            state.contactCount = try ContactSync.sync(state.imported, into: model.store)
            errorMessage = nil
            state.next()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!)
    }

    private func importVCard() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.vCard]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a vCard exported from Contacts."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let contacts = try VCardImporter.parse(try Data(contentsOf: url))
            state.imported = contacts
            state.contactCount = contacts.count
            errorMessage = contacts.isEmpty ? "That file has no contacts in it." : nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
