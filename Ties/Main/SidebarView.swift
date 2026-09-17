import SwiftUI
import TiesCore

/// The lists in the main window's first column: the four fixed ones, the people you have let
/// slip (§4.5), and whatever the provider last grouped the network into (§7.2). A smart list is
/// identified by its row id, which survives a rename and changes with every regrouping.
enum SidebarItem: Hashable {
    case all, researched, unsure, manual, reconnect
    case smartList(String)
}

/// The first column: the fixed lists, the AI's lists under a `sparkle` header with the way to
/// rebuild them, and a gear that opens Settings from the bottom bar the way Contacts.app does.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Label("All", systemImage: "person.2")
                .tag(SidebarItem.all)
            Label("Researched", systemImage: "checkmark.seal")
                .tag(SidebarItem.researched)
            Label("Unsure", systemImage: "questionmark.circle")
                .tag(SidebarItem.unsure)
            Label("Manual", systemImage: "pencil")
                .tag(SidebarItem.manual)
            Label("Reconnect", systemImage: "arrow.uturn.backward.circle")
                .tag(SidebarItem.reconnect)
                .help("People you haven't talked to in three months")

            Section {
                ForEach(model.smartLists) { list in
                    Label(list.name, systemImage: list.systemImage)
                        .tag(SidebarItem.smartList(list.id))
                        .help("\(list.personIds.count) people")
                }
            } header: {
                smartListHeader
            }
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
        .animation(.snappy, value: model.smartLists)
        .safeAreaInset(edge: .bottom) {
            HStack {
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                .accessibilityLabel("Settings")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    /// The header is also the control: it is the only place the lists can be rebuilt from, so it
    /// is shown even while there are none — that is exactly when someone wants the button.
    private var smartListHeader: some View {
        HStack(spacing: 6) {
            Label("Smart lists", systemImage: "sparkle")
            Spacer()
            if model.smartListsRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    model.refreshSmartLists()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Group everyone again")
                .accessibilityLabel("Refresh smart lists")
            }
        }
    }
}
