import SwiftUI
import TiesCore

/// The live line of a running scan or extraction: a determinate bar, a sentence saying what is
/// happening to whom *right now*, the probes already done for that person, an elapsed clock that
/// ticks, and the three controls over the run.
///
/// It owns none of that state: the screen showing it drives the run and passes back the latest
/// `ScanProgress`, so pausing is a single fact held in one place.
///
/// Everything below the bar is drawn from one event, because a long run that only ever said
/// "3 of 12" gave someone watching it no way to tell work from a hang.
struct ProgressCaptionView: View {
    /// Which run is being watched, which is the only thing the two screens showing this differ
    /// on: research walks a person through probe after probe, extraction is one AI call per
    /// person and has no stages to report.
    enum Work {
        case research, extract
    }

    let progress: ScanProgress
    /// When the run being watched started: what both the elapsed clock and the estimate are
    /// measured from. `nil` for a run whose start nobody recorded, and the caption then simply
    /// leaves the time out.
    var startedAt: Date?
    var work: Work = .research
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

            Label(headline, systemImage: headlineIcon)
                .font(.callout)
                .lineLimit(1)
                .contentTransition(.opacity)

            if !progress.finishedStages.isEmpty || progress.stage != nil {
                stages
            }

            timeLine
        }
        .animation(.snappy, value: progress)
    }

    // MARK: - What is happening

    /// What the run is doing, in the order that matters to someone watching: a backoff it is
    /// waiting out first, then the probe running right now, then whoever is being worked on.
    private var headline: String {
        if let waitingFor = progress.waitingFor {
            return "Waiting for \(waitingFor) to let us back in…"
        }
        guard let name = progress.currentName else {
            return progress.completed == 0 ? "Starting…" : "Finishing up…"
        }
        guard let stage = progress.stage else {
            switch work {
            case .research: return "Researching \(name)…"
            case .extract: return "Extracting \(name)'s profile…"
            }
        }
        // The one probe that reads rather than searches; "Searching their pages for Ada" is not
        // what it does.
        if stage == "their pages" {
            return "Reading \(name)'s pages…"
        }
        return "Searching \(stage) for \(name)…"
    }

    private var headlineIcon: String {
        if progress.waitingFor != nil { return "clock" }
        if progress.stage == "their pages" { return "doc.text.magnifyingglass" }
        if progress.stage != nil { return "magnifyingglass" }
        return work == .extract ? "sparkles" : "person.crop.circle.badge.questionmark"
    }

    /// The probes this person has been through, ticked off, with the one running now spinning at
    /// the end of them — the part that makes a slow stretch read as work rather than a hang.
    private var stages: some View {
        HStack(spacing: 6) {
            ForEach(progress.finishedStages, id: \.self) { stage in
                capsule(stage) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                }
            }
            if let stage = progress.stage {
                capsule(stage) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                }
            }
        }
        .transition(.opacity)
    }

    private func capsule(_ title: String, @ViewBuilder icon: () -> some View) -> some View {
        HStack(spacing: 4) {
            icon()
            Text(title)
        }
        .font(.caption2)
        .imageScale(.small)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    // MARK: - The clock

    /// Elapsed time and the estimate of what is left, on the left; how far through the batch the
    /// run is, small, on the right.
    ///
    /// The clock ticks once a second on its own rather than moving only when a person finishes:
    /// on a run where one person can take minutes, a caption that never changed was the whole
    /// reason to doubt anything was happening.
    private var timeLine: some View {
        TimelineView(.periodic(from: startedAt ?? .now, by: 1)) { context in
            HStack(spacing: 8) {
                Text(timing(now: context.date))
                    .monospacedDigit()
                Spacer(minLength: 0)
                if progress.total > 0 {
                    Text("\(progress.completed) of \(progress.total)")
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func timing(now: Date) -> String {
        [elapsed(now: now), timeRemaining(now: now)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// How long this run has been going, as `m:ss`.
    private func elapsed(now: Date) -> String? {
        guard let startedAt else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        return String(format: "%d:%02d elapsed", seconds / 60, seconds % 60)
    }

    /// Roughly what is left, from how long the run has taken so far — the one thing a scan that
    /// can run for hours never told anyone.
    ///
    /// Kept out of sight until two people are done. The first carries everything the run only
    /// pays for once (the search backend's WebView, the first provider call), so an estimate
    /// drawn from that one sample is wrong by a factor rather than by a bit.
    ///
    /// It never claims less than a minute: the last stretch of a long run would otherwise
    /// flicker through the seconds, and the guess was never that precise.
    private func timeRemaining(now: Date) -> String? {
        guard let startedAt, progress.completed >= 2, progress.total > progress.completed else {
            return nil
        }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed > 0 else { return nil }

        let left = elapsed / Double(progress.completed) * Double(progress.total - progress.completed)
        let formatted = Duration.seconds(max(left, 60))
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
        return "about \(formatted) left"
    }
}
