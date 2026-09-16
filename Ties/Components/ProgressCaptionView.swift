import SwiftUI
import TiesCore

/// The live line of a running scan: a determinate bar, a caption saying who is being researched
/// right now (or which backend the run is waiting out), and the three controls over the run.
///
/// It owns none of that state: the screen showing it drives the scanner and passes back the
/// latest `ScanProgress`, so pausing is a single fact held in one place.
struct ProgressCaptionView: View {
    let progress: ScanProgress
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let paused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))

                Button(action: paused ? onResume : onPause) {
                    Image(systemName: paused ? "play.circle" : "pause.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(paused ? "Resume" : "Pause")
                .help(paused ? "Resume" : "Pause")

                Button(action: onCancel) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop")
                .help("Stop researching")
            }
            .imageScale(.large)

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// What the scanner is doing, in the order that matters to someone watching: a backoff it is
    /// waiting out first, then whoever is being researched, and before either of those exist,
    /// that the run is only just starting.
    private var caption: String {
        if let waitingFor = progress.waitingFor {
            return "Waiting for \(waitingFor)…"
        }
        if let name = progress.currentName {
            return "Researching \(name) · \(progress.completed) of \(progress.total)"
        }
        if progress.total == 0 {
            return "Starting…"
        }
        return "\(progress.completed) of \(progress.total)"
    }
}
