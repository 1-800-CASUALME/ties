import SwiftUI
import TiesCore

/// The alphabetical contact list the whole app shares: setup's Select and Review screens and
/// the main window all draw the same rows from it.
///
/// It is told which `people` to show and filters them itself against `query`; what a row does
/// when tapped depends on which binding it was given. `selection` puts a checkbox on every row
/// and makes the whole row toggle it (setup's multi-select), `activeId` makes it a single-
/// selection list with the system highlight (the main window's sidebar), and with neither the
/// list is just a read-only roster.
struct ContactListView<Trailing: View>: View {
    @Environment(AppModel.self) private var model

    let people: [Person]
    @Binding var query: String
    var selection: Binding<Set<String>>?
    var activeId: Binding<String?>?
    var subtitle: (Person) -> String?
    @ViewBuilder var trailing: (Person) -> Trailing

    init(
        people: [Person],
        query: Binding<String>,
        selection: Binding<Set<String>>? = nil,
        activeId: Binding<String?>? = nil,
        subtitle: @escaping (Person) -> String? = { _ in nil },
        @ViewBuilder trailing: @escaping (Person) -> Trailing
    ) {
        self.people = people
        self._query = query
        self.selection = selection
        self.activeId = activeId
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        Group {
            if let activeId {
                // The system list selection, so arrow keys and the highlight come for free.
                List(selection: activeId) { sections }
            } else {
                List { sections }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .animation(.snappy, value: filtered.map(\.id))
    }

    @ViewBuilder
    private var sections: some View {
        ForEach(ContactSectioner.sections(filtered, name: \.displayName)) { section in
            Section(header: Text(section.letter)) {
                ForEach(section.items) { person in
                    row(person)
                }
            }
        }
    }

    private func row(_ person: Person) -> some View {
        HStack(spacing: 10) {
            if let selection {
                Toggle(person.displayName, isOn: isSelected(person.id, in: selection))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            AvatarView(data: person.thumbnail, name: person.displayName, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(person.displayName)
                    .font(.body)
                if let subtitle = subtitle(person), !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing(person)
        }
        .frame(height: 44)
        // So the empty space right of the name is part of the row, not a gap between targets.
        .contentShape(Rectangle())
        .onTapGesture {
            guard let selection else { return }
            isSelected(person.id, in: selection).wrappedValue.toggle()
        }
    }

    /// The rows to show: everything when the search field is empty, otherwise the store's own
    /// matches — it is the only thing that can match phone digits — narrowed to `people` and
    /// kept in the order they were given in.
    private var filtered: [Person] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return people }
        let matches = (try? model.store.people(matchingNameOrDigits: query)) ?? []
        let ids = Set(matches.map(\.id))
        return people.filter { ids.contains($0.id) }
    }

    private func isSelected(_ id: String, in selection: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { selection.wrappedValue.contains(id) },
            set: { isOn in
                if isOn {
                    selection.wrappedValue.insert(id)
                } else {
                    selection.wrappedValue.remove(id)
                }
            }
        )
    }
}

extension ContactListView where Trailing == EmptyView {
    /// A list with nothing on the right of a row, which is most of them.
    init(
        people: [Person],
        query: Binding<String>,
        selection: Binding<Set<String>>? = nil,
        activeId: Binding<String?>? = nil,
        subtitle: @escaping (Person) -> String? = { _ in nil }
    ) {
        self.init(
            people: people,
            query: query,
            selection: selection,
            activeId: activeId,
            subtitle: subtitle,
            trailing: { _ in EmptyView() }
        )
    }
}
