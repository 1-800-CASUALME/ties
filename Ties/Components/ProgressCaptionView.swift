import SwiftUI
import TiesCore

/// The live line of a running scan: a determinate bar, a caption saying who is being researched
/// right now (or which backend the run is waiting out), and the three controls over the run.
///
/// It owns none of that state: the screen showing it drives the scanner and passes back the
/// latest `ScanProgress`, so pausing is a single fact held in one place.
struct ProgressCaptionView: View {
    let progress: ScanProgress
    /// When the run being watched started, which is what the estimate in the caption is
    /// measured from. `nil` for a run whose start nobody recorded, and the caption then simply
    /// leaves the estimate out.
    var startedAt: Date?
    /// Only asked for when `showsPause` is on; a run that can't be paused leaves both alone.
    var onPause: () -> Void = {}
    var onResume: () -> Void = {}
    let onCancel: () -> Void
    let paused: Bool
    /// Off for runs that can only be stopped, never held — extraction is one — so they don't
    /// show a button that would do nothing.
    var showsPause = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))

                if showsPause {
                    Button(action: paused ? onResume : onPause) {
                        Image(systemName: paused ? "play.circle" : "pause.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(paused ? "Resume" : "Pause")
                    .help(paused ? "Resume" : "Pause")
                }

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
    /// waiting out first, then whoever is being researched, how far through the batch it is,
    /// and how much longer it is likely to take. Before any of that exists, that the run is
    /// only just starting.
    private var caption: String {
        if let waitingFor = progress.waitingFor {
            return "Waiting for \(waitingFor)…"
        }
        if progress.total == 0, progress.currentName == nil {
            return "Starting…"
        }

        var line = progress.currentName.map { "Researching \($0) · " } ?? ""
        line += "\(progress.completed) of \(progress.total)"
        if let timeRemaining {
            line += " · \(timeRemaining)"
        }
        return line
    }

    /// Roughly what is left, from how long the run has taken so far — the one thing a scan that
    /// can run for hours never told anyone.
    ///
    /// Kept out of sight until two people are done. The first carries everything the run only
    /// pays for once (the search backend's WebView, the first provider call), so an estimate
    /// drawn from that one sample is wrong by a factor rather than by a bit.
    ///
    /// It is recomputed on each progress event — once per person — rather than ticking on its
    /// own, so it settles as the run goes instead of counting down in front of the user, and it
    /// never claims less than a minute: the last stretch of a long run would otherwise flicker
    /// through the seconds, and the guess was never that precise.
    private var timeRemaining: String? {
        guard let startedAt, progress.completed >= 2, progress.total > progress.completed else {
            return nil
        }
        let elapsed = Date.now.timeIntervalSince(startedAt)
        guard elapsed > 0 else { return nil }

        let left = elapsed / Double(progress.completed) * Double(progress.total - progress.completed)
        let formatted = Duration.seconds(max(left, 60))
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
        return "about \(formatted) left"
    }
}
