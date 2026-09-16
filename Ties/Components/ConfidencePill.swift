import SwiftUI
import TiesCore

/// How sure the research is that a candidate really is this person, as a small tinted capsule.
///
/// Status is the only thing it reads. The scorer already turned the score into a status using
/// its own thresholds, and the user can overrule that by accepting or rejecting a candidate; a
/// pill that looked at the number again could disagree with the decision the rest of the app has
/// already acted on — a rejected candidate reading "High", or an accepted one reading "Unsure".
/// The score is still worth seeing, so it is the tooltip.
struct ConfidencePill: View {
    let score: Double
    let status: Candidate.Status

    var body: some View {
        Text(label)
            .font(.caption2.bold())
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.15)))
            .help("Match score \(formattedScore)")
            .accessibilityLabel("Confidence: \(label)")
            .accessibilityValue("Match score \(formattedScore)")
    }

    private var label: String {
        switch status {
        case .accepted: "Chosen"
        case .auto: "High"
        case .pending: "Unsure"
        case .rejected: "No"
        }
    }

    private var tint: Color {
        switch status {
        case .accepted, .auto: .green
        case .pending: .orange
        case .rejected: .gray
        }
    }

    private var formattedScore: String {
        score.formatted(.number.precision(.fractionLength(2)))
    }
}
