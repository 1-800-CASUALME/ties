import SwiftUI
import TiesCore

/// Fourth screen of setup: pick which of the imported contacts are worth researching.
struct SelectView: View {
    @Environment(AppModel.self) private var model
    @Environment(WizardState.self) private var state
    @State private var people: [Person] = []
    @State private var query = ""
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $query)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("Select All", isOn: allSelected)
                    .toggleStyle(.checkbox)
                    .disabled(people.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding(.bottom, 8)
            }

            ContactListView(
                people: people,
                query: $query,
                selection: $state.selectedIds,
                subtitle: { $0.organization }
            )

            PrimaryButton("Research \(state.selectedIds.count)") { state.next() }
                .disabled(state.selectedIds.isEmpty)
                .padding(.vertical, 16)
        }
        .padding(.top, 24)
        .onAppear(perform: load)
    }

    /// Whether every contact is picked, and the way to pick or drop them all at once. Empty
    /// means off — there is nothing to select — so the toggle can never read as "all done"
    /// when the list is blank.
    private var allSelected: Binding<Bool> {
        Binding(
            get: { !people.isEmpty && state.selectedIds.count == people.count },
            set: { isOn in state.selectedIds = isOn ? Set(people.map(\.id)) : [] }
        )
    }

    private func load() {
        do {
            people = try model.store.allPeople()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
