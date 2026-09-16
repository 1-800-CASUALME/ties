import SwiftUI
import TiesCore

/// How sure the research is that a candidate really is this person, as a small tinted capsule.
///
/// The cut-offs are the scorer's own (`ScoringWeights.default`) rather than numbers typed in
/// here, so the pill can never disagree with the scan that set the status. A status the user
/// has settled — an accepted candidate — outranks the score entirely.
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
            .accessibilityLabel("Confidence: \(label)")
    }

    private enum Level {
        case chosen, high, unsure, none
    }

    private var level: Level {
        let weights = ScoringWeights.default
        if status == .accepted { return .chosen }
        if status == .auto || score >= weights.autoThreshold { return .high }
        if score >= weights.pendingThreshold { return .unsure }
        return .none
    }

    private var label: String {
        switch level {
        case .chosen: "Chosen"
        case .high: "High"
        case .unsure: "Unsure"
        case .none: "None"
        }
    }

    private var tint: Color {
        switch level {
        case .chosen, .high: .green
        case .unsure: .orange
        case .none: .gray
        }
    }
}
