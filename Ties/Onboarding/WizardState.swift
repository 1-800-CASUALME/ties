import Observation
import SwiftUI
import TiesCore

/// The eight screens of first-run setup, in order. The raw values drive both `StepDots` and
/// `next()`/`back()`.
enum WizardStep: Int, CaseIterable {
    case welcome, access, select, scan, review, provider, extract, done
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
    var extractProgress = ScanProgress(completed: 0, total: 0)
    /// When each run in flight started, which is what the "about 4 min left" in its caption is
    /// measured from. Beside the progress rather than on the screen watching it, so a screen
    /// rebuilt mid-run — or one that picks up a run it didn't start — still has the beginning
    /// of it to measure from.
    var scanStartedAt: Date?
    var extractStartedAt: Date?
    var selectedForExtract: Set<String> = []
    /// The runs in flight, held here rather than on the screens watching them: a screen that is
    /// rebuilt must not start a second run over people the first one is already working through,
    /// and the stop button has to reach the actor the stream came from. Both are cleared the
    /// moment their stream ends.
    var scanner: ResearchScanner?
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
}
