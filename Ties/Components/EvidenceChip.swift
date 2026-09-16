import SwiftUI
import TiesCore

/// One reason a candidate scored the way it did: the detail that matched, with an icon for what
/// kind of match it was. Conflicts are the only kind tinted red — every other kind is evidence
/// for the match, not against it.
struct EvidenceChip: View {
    let evidence: Evidence

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(evidence.detail)
                .lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.15)))
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch evidence.kind {
        case .emailHash: "envelope"
        case .phone: "phone"
        case .company: "building.2"
        case .location: "mappin"
        case .name: "person"
        case .username: "at"
        case .avatar: "photo"
        case .conflict: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        evidence.kind == .conflict ? .red : .secondary
    }
}
