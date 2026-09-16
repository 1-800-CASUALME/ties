import AppKit
import SwiftUI
import TiesCore

/// One provider in the setup picker: its logo on a rounded material square, with a green dot
/// when the provider was detected on this Mac and a tinted ring when it is the chosen one.
///
/// The name is kept hidden until the tile is selected or hovered, so a grid of 26 providers
/// reads as logos rather than a wall of text; it stays in the accessibility label throughout.
struct LogoTile: View {
    private let spec: ProviderSpec
    private let detected: DetectResult?
    private let selected: Bool
    private let action: () -> Void

    @State private var hovering = false

    init(_ spec: ProviderSpec, detected: DetectResult?, selected: Bool, action: @escaping () -> Void) {
        self.spec = spec
        self.detected = detected
        self.selected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                logo
                    .frame(width: 40, height: 40)
                Text(spec.name)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                    .opacity(showsName ? 1 : 0)
            }
            .padding(.horizontal, 4)
            .frame(width: 84, height: 84)
            .background(RoundedRectangle(cornerRadius: 16).fill(.thinMaterial))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                    .padding(8)
                    .opacity(isAvailable ? 1 : 0)
            }
            .scaleEffect(selected ? 1.06 : 1)
            .animation(.snappy, value: selected)
            .animation(.snappy, value: showsName)
            .animation(.snappy, value: isAvailable)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(spec.name)
        .accessibilityLabel(spec.name)
        .accessibilityValue(isAvailable ? "Ready on this Mac" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The bundled SVG when `scripts/fetch-logos.sh` found one for this provider, and an SF
    /// Symbol standing in for it when it didn't — a missing asset is a normal outcome, not a
    /// broken build, so the grid must stay complete either way.
    @ViewBuilder
    private var logo: some View {
        if NSImage(named: spec.logo) != nil {
            Image(spec.logo)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: 26))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
    }

    /// `custom` has no brand to show by design; the two local runners are the ones lobe-icons
    /// and simple-icons don't carry.
    private var fallbackSymbol: String {
        switch spec.id {
        case "llamacpp": "cpu"
        case "gpt4all": "desktopcomputer"
        case "custom": "puzzlepiece.extension"
        default: "sparkles"
        }
    }

    private var isAvailable: Bool {
        if case .available = detected { return true }
        return false
    }

    private var showsName: Bool { selected || hovering }
}
