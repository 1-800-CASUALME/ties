import SwiftUI
import TiesCore

/// The live line of a running scan or extraction: a determinate bar, a sentence saying what is
/// happening to whom *right now*, the probes already done for that person, a countdown to the
/// end of the run beside the time it has already taken, and the three controls over the run.
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

    /// The countdown's fixed point: how much was left, and the moment that was worked out.
    /// Re-derived from the run's own pace on every progress event and simply counted down from
    /// in between, which is what lets the line move every second instead of lurching once per
    /// person. `nil` until there is enough of the run to estimate from.
    @State private var estimate: Estimate?

    /// A remaining-time estimate and when it was made.
    private struct Estimate {
        var madeAt: Date
        var seconds: TimeInterval
    }

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

            if let notice = progress.notice {
                noticeBanner(notice)
            }

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
        .onChange(of: progress, initial: true) { _, latest in
            reestimate(latest)
        }
    }

    // MARK: - What is happening

    /// A run-level warning from the scanner — so far, that web search has been switched off
    /// after the engine challenged twice. Sits right under the bar, where the research-engine
    /// menu beside it is the obvious thing to do about it.
    private func noticeBanner(_ notice: String) -> some View {
        Label {
            Text(notice)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
        }
        .font(.caption)
        .lineLimit(2)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .transition(.opacity)
    }

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

    /// What is left and what has gone, on the left; how far through the batch the run is,
    /// small, on the right.
    ///
    /// Only the countdown itself sits inside the `TimelineView`: it is redrawn every second,
    /// and there is no reason for the rest of the caption to be rebuilt at that rate.
    private var timeLine: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: startedAt ?? .now, by: 1)) { context in
                Text(timing(now: context.date))
                    .monospacedDigit()
            }
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

    /// "12:34 left · 2:10 elapsed" — the countdown first, because on a run over hundreds of
    /// people it is the only half anyone is actually asking about.
    private func timing(now: Date) -> String {
        [countdown(now: now), elapsed(now: now)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// How long this run has been going.
    private func elapsed(now: Date) -> String? {
        guard let startedAt else { return nil }
        return "\(clock(now.timeIntervalSince(startedAt))) elapsed"
    }

    /// What is left, counted down a second at a time from the last estimate rather than held
    /// still between people: a number that only ever moved when somebody finished was the whole
    /// reason to doubt anything was happening.
    ///
    /// It never goes below 0:00 — an estimate the run has outlived is wrong, but a negative
    /// clock is nonsense — and says "estimating…" until there is a pace worth quoting. Nothing
    /// at all once the last person is done: there is no time left to report.
    private func countdown(now: Date) -> String? {
        guard startedAt != nil, progress.total > progress.completed else { return nil }
        guard let estimate else { return "estimating…" }
        let left = max(0, estimate.seconds - now.timeIntervalSince(estimate.madeAt))
        return "\(clock(left)) left"
    }

    /// Re-derives the estimate from the pace of the run so far: the average a finished person
    /// has cost, times the people still to go.
    ///
    /// It waits for two people. The first carries everything the run only pays for once (the
    /// search backend's WebView, the first provider call), so an estimate drawn from that one
    /// sample is wrong by a factor rather than by a bit.
    private func reestimate(_ progress: ScanProgress) {
        guard let startedAt, progress.completed >= 2, progress.total > progress.completed else {
            estimate = nil
            return
        }
        let now = Date.now
        let spent = now.timeIntervalSince(startedAt)
        guard spent > 0 else { return }
        let perPerson = spent / Double(progress.completed)
        estimate = Estimate(madeAt: now, seconds: perPerson * Double(progress.total - progress.completed))
    }

    /// `m:ss`, or `h:mm:ss` once a run has been going for an hour — which, on hundreds of
    /// people, it will be.
    private func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        let (hours, minutes, remainder) = (seconds / 3600, seconds % 3600 / 60, seconds % 60)
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}
