import SwiftUI
import TiesCore

/// How deep the research goes, as two icons: a hare and a tortoise.
///
/// Shown on the Scan screen beside the engine menu and again in Settings, because the moment
/// the choice matters is while watching a batch of hundreds crawl — and the moment after that
/// is when the same person goes looking for where to change it for good.
struct ScanModePicker: View {
    @Binding var mode: ScanMode

    var body: some View {
        Picker("Research", selection: $mode) {
            Label("Quick", systemImage: "hare")
                .labelStyle(.iconOnly)
                .help("Quick: 1–2 searches, 15 username sites, 3 pages per person")
                .tag(ScanMode.quick)
            Label("Thorough", systemImage: "tortoise")
                .labelStyle(.iconOnly)
                .help("Thorough: 4 searches, 40 sites, all pages")
                .tag(ScanMode.thorough)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("How deep the research goes")
    }
}
