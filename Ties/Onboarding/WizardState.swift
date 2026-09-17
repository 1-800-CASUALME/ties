import Observation
import SwiftUI
import TiesCore

/// The nine screens of first-run setup, in order. The raw values drive both `StepDots` and
/// `next()`/`back()`.
enum WizardStep: Int, CaseIterable {
    case welcome, access, sources, select, scan, review, provider, extract, done

    /// One word per step, for the tooltip on its dot.
    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .access: "Contacts"
        case .sources: "Sources"
        case .select: "Select"
        case .scan: "Research"
        case .review: "Review"
        case .provider: "AI"
        case .extract: "Extract"
        case .done: "Done"
        }
    }
}

/// Everything the setup wizard collects as the user moves through it: contacts imported,
/// people selected, scan and extraction progress, and the chosen provider. Owned by
/// `WizardWindow` and handed to every screen through the environment; it is deliberately
/// separate from `AppModel` because all of it is thrown away once setup finishes.
@MainActor
@Observable
final class WizardState {
    var step: WizardStep = .welcome
    /// Which edge the incoming screen slides in from, so `back()` reverses the push.
    var direction: Edge = .trailing

    var access: ContactsAccess = .notDetermined
    var contactCount = 0
    /// Contacts read from the address book, or parsed from a `.vcf` when access is denied.
    var imported: [ImportedContact] = []
    /// Person ids (equal to `ImportedContact.identifier` after the sync) chosen for research.
    var selectedIds: Set<String> = []

    var scanProgress = ScanProgress(completed: 0, total: 0)
    /// The signal collection that runs on the Research step before the scanner, kept apart from
    /// `scanProgress` so the two runs can't be read as one: they cover the same people but count
    /// their own, and the caption switches from one to the other when the reading is done.
    var collectProgress = ScanProgress(completed: 0, total: 0)
    var extractProgress = ScanProgress(completed: 0, total: 0)
    /// When each run in flight started, which is what the "about 4 min left" in its caption is
    /// measured from. Beside the progress rather than on the screen watching it, so a screen
    /// rebuilt mid-run — or one that picks up a run it didn't start — still has the beginning
    /// of it to measure from.
    var scanStartedAt: Date?
    var collectStartedAt: Date?
    var extractStartedAt: Date?
    var selectedForExtract: Set<String> = []
    /// The runs in flight, held here rather than on the screens watching them: a screen that is
    /// rebuilt must not start a second run over people the first one is already working through,
    /// and the stop button has to reach the actor the stream came from. Both are cleared the
    /// moment their stream ends.
    var scanner: ResearchScanner?
    /// The signal collection in flight, held for the same reasons the scanner is: it reads the
    /// Mac's own stores, and a run nobody is watching must still be stoppable.
    var collector: SignalCollector?
    var extractor: Extractor?

    var providerId: String?
    /// What `ProviderDetector` found for each provider id on the provider screen.
    var detections: [String: DetectResult] = [:]

    func next() {
        guard let step = WizardStep(rawValue: step.rawValue + 1) else { return }
        direction = .trailing
        withAnimation(.snappy) { self.step = step }
    }

    func back() {
        guard let step = WizardStep(rawValue: step.rawValue - 1) else { return }
        direction = .leading
        withAnimation(.snappy) { self.step = step }
    }

    /// Goes straight to `step`, which is what clicking one of the dots means. The push runs the
    /// way the user is travelling, so jumping back still reads as going back.
    ///
    /// Leaving a run behind stops it first. The screen watching it goes away with the jump, and
    /// a scanner nobody is reading from would keep working through people and writing candidates
    /// for a screen that is gone — and, worse, would still be there on a later visit, leaving
    /// that screen watching a stream it has no loop for.
    func jump(to step: WizardStep) {
        guard step != self.step else { return }
        if self.step == .scan || self.step == .extract {
            let scanner = scanner
            let collector = collector
            let extractor = extractor
            self.scanner = nil
            self.collector = nil
            self.extractor = nil
            Task {
                await scanner?.cancel()
                await collector?.cancel()
                await extractor?.cancel()
            }
        }
        direction = step.rawValue > self.step.rawValue ? .trailing : .leading
        withAnimation(.snappy) { self.step = step }
    }
}
