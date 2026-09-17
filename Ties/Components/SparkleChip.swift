import SwiftUI

/// The mark every AI-produced element in the app carries (§7): a `sparkle` and the short reason
/// the model gave, with the whole sentence in the tooltip.
///
/// It is a label, never a decision — a chip on a candidate row says the model would pick that
/// one, and the user still has to. Nothing about it accepts anything.
struct SparkleChip: View {
    let reason: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkle")
            Text(reason)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
        .help("AI pick: " + reason)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI pick: \(reason)")
    }
}
