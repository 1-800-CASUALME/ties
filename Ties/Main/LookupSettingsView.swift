import AppKit
import SwiftUI
import TiesCore

/// Settings › Lookup: the one source that asks somebody else.
///
/// Ties ships no crowd-sourced "what do other people call this number" database of its own, and
/// integrates with none: those are built by uploading everybody's address book, which is the one
/// thing Ties promises never to do. What it ships instead is the slot — a documented commercial
/// service, and a described-not-coded endpoint for whatever the user already has access to. The
/// grid, the keys and the switch look like the AI provider grid because they are the same idea:
/// you choose, you pay, you can leave it empty.
struct LookupSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var selectedId: String?
    @State private var config = CustomLookupConfig()
    @State private var budget = LookupSettings.defaultBudget
    @State private var testNumber = ""
    @State private var testing = false
    @State private var testResult: LookupResult?
    @State private var testMessage: String?

    private var spec: LookupSpec? { selectedId.flatMap(LookupCatalog.spec) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ForEach(LookupCatalog.all) { spec in
                        LookupTile(spec, selected: selectedId == spec.id, configured: isConfigured(spec.id)) {
                            choose(spec.id)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            } footer: {
                Text(spec?.coverage ?? "Nothing is asked of anyone until you choose a service here. Your contacts' numbers stay on this Mac while this is empty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let spec {
                Section {
                    if let identifierLabel = spec.identifierLabel {
                        KeyField(title: identifierLabel, account: LookupCatalog.identifierAccount(spec.id), onChange: { _ in refreshStatus() })
                    }
                    KeyField(title: spec.secretLabel, account: LookupCatalog.secretAccount(spec.id), onChange: { _ in refreshStatus() })
                    if let keyURL = spec.keyURL, let url = URL(string: keyURL) {
                        Link(destination: url) {
                            Label("Get a key", systemImage: "key")
                        }
                        .font(.callout)
                    }
                }

                if spec.id == LookupCatalog.customId {
                    customEndpointSection
                }

                Section {
                    Stepper(value: budgetBinding, in: LookupSettings.budgetRange, step: 25) {
                        Label {
                            Text("\(budget) lookups per pass")
                                .monospacedDigit()
                        } icon: {
                            Image(systemName: "gauge.with.dots.needle.33percent")
                        }
                    }
                    .help("The most one collection may spend")
                    testRow
                } footer: {
                    Text("A lookup is billed per number, and the same number is asked about once however many contacts share it. Names registered to a line are treated like a name someone set themselves; names other people saved are shown as \u{201C}known as\u{201D} and never used on their own to accept a profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .animation(.snappy, value: selectedId)
        .onAppear {
            selectedId = LookupSettings.selectedId()
            config = LookupSettings.customConfig()
            budget = LookupSettings.budget()
        }
    }

    // MARK: - The described endpoint

    @ViewBuilder
    private var customEndpointSection: some View {
        Section {
            TextField("URL", text: field(\.urlTemplate), prompt: Text("https://api.example.com/v1/numbers/{phone_plain}"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            HStack(spacing: 8) {
                TextField("Header", text: optionalField(\.headerName), prompt: Text("Authorization"))
                TextField("Header value", text: field(\.headerTemplate), prompt: Text("Bearer {key}"))
            }
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()

            LabeledContent("Names") {
                HStack(spacing: 8) {
                    TextField("Path", text: field(\.namesPath), prompt: Text("result.tags[]"))
                    TextField("Field", text: optionalField(\.nameField), prompt: Text("tag"))
                        .frame(width: 90)
                    TextField("Count", text: optionalField(\.countField), prompt: Text("count"))
                        .frame(width: 80)
                }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            }
            LabeledContent("Tags") {
                HStack(spacing: 8) {
                    TextField("Path", text: field(\.tagsPath), prompt: Text("result.labels[]"))
                    TextField("Field", text: optionalField(\.tagField), prompt: Text("label"))
                        .frame(width: 90)
                }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            }

            Toggle("Names come from other people, not the line", isOn: field(\.namesAreCrowd))
                .toggleStyle(.switch)
        } header: {
            Text("Endpoint")
        } footer: {
            Text("{phone} is the number in full, {phone_plain} its digits, {email} and {name} the other two. A path walks the answer — result.tags[] means every item of that array — and the field names the key to read out of each item.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Trying it

    private var testRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Try a number", text: $testNumber, prompt: Text("+1 555 123 4567"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(runTest)
                Button(action: runTest) {
                    Label("Try", systemImage: "play.circle")
                }
                .disabled(testing || testNumber.trimmingCharacters(in: .whitespaces).isEmpty)
                if testing {
                    ProgressView().controlSize(.small)
                }
            }
            if let testResult {
                answer(testResult)
            }
            if let testMessage {
                Label(testMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Everything the service said, including the parts `LocalSignals` has no column for — the
    /// carrier, the line type, a name-match score. Ties keeps the names and the labels; this row
    /// is where the rest is not hidden.
    private func answer(_ result: LookupResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(result.names, id: \.value) { name in
                    chip(
                        name.value,
                        symbol: name.kind == .registered ? "checkmark.seal.fill" : "person.2.fill",
                        count: name.count
                    )
                }
            }
            HStack(spacing: 6) {
                ForEach(result.tags, id: \.self) { tag in
                    chip(tag, symbol: "tag.fill", count: nil)
                }
            }
            HStack(spacing: 12) {
                if let carrier = result.carrier {
                    Label(carrier, systemImage: "antenna.radiowaves.left.and.right")
                }
                if let lineType = result.lineType {
                    Label(lineType, systemImage: "phone")
                }
                if let match = result.nameMatch {
                    Label("\(Int(match * 100))% name match", systemImage: "person.crop.circle.badge.checkmark")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .transition(.opacity)
    }

    /// A name or a label as it came back, with how many people used it when the service counts.
    /// The seal says the line is registered under it; the two people say a crowd saved it.
    private func chip(_ text: String, symbol: String, count: Int?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(text)
            if let count {
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }

    private func runTest() {
        let number = testNumber.trimmingCharacters(in: .whitespaces)
        guard !number.isEmpty else { return }
        commitConfig()
        testing = true
        testResult = nil
        testMessage = nil

        let client = model.http
        Task {
            guard let provider = LookupSettings.makeProvider(client: client) else {
                testing = false
                testMessage = "Add the key first."
                return
            }
            do {
                let result = try await provider.lookup(LookupQuery(phoneE164: number))
                withAnimation(.snappy) { testResult = result }
                if result == nil { testMessage = "The service has nothing on that number." }
            } catch {
                testMessage = Self.describe(error)
            }
            testing = false
            refreshStatus()
        }
    }

    static func describe(_ error: any Error) -> String {
        guard let error = error as? LookupError else { return error.localizedDescription }
        switch error {
        case .notConfigured: return "Fill in the URL first."
        case .unauthorized: return "The key was refused."
        case .rateLimited: return "The service asked Ties to slow down."
        case .http(let code): return "The service answered \(code)."
        case .malformed(let detail): return detail
        }
    }

    // MARK: - Writing it down

    private func choose(_ id: String) {
        selectedId = selectedId == id ? nil : id
        LookupSettings.setSelectedId(selectedId)
        testResult = nil
        testMessage = nil
        refreshStatus()
    }

    private func isConfigured(_ id: String) -> Bool {
        Keychain.get(account: LookupCatalog.secretAccount(id))?.isEmpty == false
    }

    private var budgetBinding: Binding<Int> {
        Binding(
            get: { budget },
            set: {
                budget = $0
                LookupSettings.setBudget($0)
            }
        )
    }

    /// A field of the custom config, saved as it is typed — there is no "done" on a form of text
    /// fields, and the next collection is what reads them.
    private func field<Value>(_ path: WritableKeyPath<CustomLookupConfig, Value>) -> Binding<Value> {
        Binding(
            get: { config[keyPath: path] },
            set: {
                config[keyPath: path] = $0
                commitConfig()
            }
        )
    }

    /// The same, for the fields that are optional: an empty box means "this service doesn't have
    /// one", which is `nil` rather than `""`.
    private func optionalField(_ path: WritableKeyPath<CustomLookupConfig, String?>) -> Binding<String> {
        Binding(
            get: { config[keyPath: path] ?? "" },
            set: {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                config[keyPath: path] = trimmed.isEmpty ? nil : trimmed
                commitConfig()
            }
        )
    }

    private func commitConfig() {
        LookupSettings.setCustomConfig(config)
        refreshStatus()
    }

    /// The Sources row is what tells the user whether a pass will call anything, so it re-reads
    /// whenever the answer here could have changed.
    private func refreshStatus() {
        Task { await model.sources.refresh() }
    }
}

// MARK: - One service in the grid

/// One lookup service: its logo on a rounded material square, a green dot when it has a key, and
/// a tinted ring when it is the chosen one. The same tile as the AI grid, for the same reason —
/// a logo is recognised faster than its name is read.
private struct LookupTile: View {
    private let spec: LookupSpec
    private let selected: Bool
    private let configured: Bool
    private let action: () -> Void

    @State private var hovering = false

    init(_ spec: LookupSpec, selected: Bool, configured: Bool, action: @escaping () -> Void) {
        self.spec = spec
        self.selected = selected
        self.configured = configured
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                logo
                    .frame(width: 40, height: 40)
                Text(spec.name)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .opacity(selected || hovering ? 1 : 0)
            }
            .frame(width: 84, height: 84)
            .background(RoundedRectangle(cornerRadius: 16).fill(.thinMaterial))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                    .padding(8)
                    .opacity(configured ? 1 : 0)
            }
            .scaleEffect(selected ? 1.06 : 1)
            .animation(.snappy, value: selected)
            .animation(.snappy, value: configured)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(spec.name)
        .accessibilityLabel(spec.name)
        .accessibilityValue(configured ? "Has a key" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var logo: some View {
        if NSImage(named: spec.logo) != nil {
            Image(spec.logo)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 26))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
    }
}
