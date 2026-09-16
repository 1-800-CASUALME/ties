import SwiftUI

/// The lists in the main window's first column. `smartList` is the saved-search case the design
/// calls for; nothing creates one in v1, so nothing draws one either — the case is here so the
/// list column's filtering already has a shape for it.
enum SidebarItem: Hashable {
    case all, researched, unsure, manual
    case smartList(String)
}

/// The first column: four fixed lists, and a gear that opens Settings from the bottom bar the
/// way Contacts.app does.
struct SidebarView: View {
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
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
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
}
