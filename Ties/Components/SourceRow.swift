import AppKit
import SwiftUI
import TiesCore

/// One local source, drawn the same way in the wizard's Sources step and in Settings › Sources:
/// the app's own icon, its name, a glyph saying where it stands, and the switch that says whether
/// Ties may read it.
///
/// No subtitle. What a source contributes is the whole app's subject, and four rows each
/// explaining themselves would be a paragraph where a row will do; the glyph carries the one
/// thing that varies, in its tooltip.
struct SourceRow: View {
    let source: SourcesModel.Source
    /// The installed app's icon. `nil` falls back to the source's SF Symbol.
    let icon: NSImage?
    let status: SourceStatus
    @Binding var enabled: Bool

    /// A source this Mac hasn't got has nothing to switch on, so the whole row goes quiet rather
    /// than offering a toggle that would mean nothing.
    private var unavailable: Bool { status == .unavailable }

    var body: some View {
        HStack(spacing: 12) {
            appIcon
                .frame(width: 28, height: 28)

            Text(source.name)

            Spacer(minLength: 12)

            statusGlyph

            Toggle(source.name, isOn: $enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Let Ties read \(source.name)")
                .accessibilityLabel("Read \(source.name)")
        }
        .padding(.vertical, 4)
        .opacity(unavailable ? 0.55 : 1)
        .disabled(unavailable)
        .animation(.snappy, value: status)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: source.fallbackSymbol)
                .font(.system(size: 21))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
    }

    private var statusGlyph: some View {
        let glyph = glyph()
        return Image(systemName: glyph.symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(glyph.tint)
            .imageScale(.large)
            .help(glyph.help)
            .accessibilityLabel(glyph.help)
    }

    /// What the row says about this source, and the tooltip that explains it: the three states
    /// from the spec, plus whatever a collector said when it went wrong.
    private func glyph() -> (symbol: String, tint: Color, help: String) {
        switch status {
        case .ready:
            return ("checkmark.circle.fill", .green, "Ready")
        case .needsAccess:
            return ("lock.fill", .orange, "Needs Full Disk Access")
        case .unavailable:
            return ("minus.circle", .secondary, source.unavailableHelp)
        case .error(let message):
            return ("exclamationmark.triangle.fill", .yellow, message)
        }
    }
}
