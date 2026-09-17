import AppKit
import SwiftUI
import TiesCore

/// The first draft of a message to one person (§7.4): one field asking what the user needs, and
/// a draft they can edit and then take to Messages, WhatsApp or Mail themselves.
///
/// Ties never sends anything. Every button here opens the app the user already uses with the
/// text prefilled, which is also why nothing is disabled on the strength of an app being
/// installed: macOS decides who answers a URL scheme, not this view.
struct DraftPopover: View {
    @Environment(AppModel.self) private var model

    let person: Person
    let facts: ProfileFacts?
    let channels: [Channel]

    @State private var need = ""
    @State private var draft = ""
    @State private var drafting = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("What do you need?", text: $need)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(write)
                    .accessibilityLabel("What do you need from \(person.displayName)?")
                if drafting {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if !draft.isEmpty {
                TextEditor(text: $draft)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(height: 96)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
                    .accessibilityLabel("Draft message")

                HStack(spacing: 8) {
                    send("Messages", symbol: "message.fill", enabled: messagesURL != nil) { open(messagesURL) }
                    send("WhatsApp", symbol: "bubble.left.and.bubble.right.fill", enabled: whatsappURL != nil) { open(whatsappURL) }
                    send("Mail", symbol: "envelope.fill", enabled: mailURL != nil) { open(mailURL) }
                    Spacer(minLength: 0)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                Text("Nothing is sent. The app opens with the draft in it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                PrimaryButton(draft.isEmpty ? "Draft" : "Draft again", action: write)
                    .disabled(drafting || need.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
        .animation(.snappy, value: draft.isEmpty)
        .onDisappear { task?.cancel() }
    }

    private func send(_ title: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.bordered)
        .clipShape(Capsule())
        .disabled(!enabled)
        .help(enabled ? "Open \(title) with this draft" : "No \(title.lowercased()) details for \(person.displayName)")
    }

    // MARK: - Writing the draft

    /// Asks the provider for a draft in the user's own register (§7.4): their last messages to
    /// this person are read from whichever chat store this Mac has, and go to the drafter along
    /// with what is already known about them.
    private func write() {
        let question = need.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !drafting else { return }

        let drafter: MessageDrafter
        do {
            drafter = try model.makeDrafter()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        drafting = true
        errorMessage = nil
        let person = person
        let facts = facts
        let probe = ProbeInput(person: person, channels: channels)
        let stores = sampleStores
        task = model.track {
            // The spinner stops however this ends — answered, failed, or cancelled by the
            // popover closing while a slow store was still being read.
            defer { drafting = false }
            // Read here rather than on the way into the popover: a register sample comes out of
            // a copy of a chat store, which is by far the slowest thing this view touches.
            let sample = await Self.registerSample(for: probe, from: stores)
            guard !Task.isCancelled else { return }
            do {
                let written = try await drafter.draft(
                    need: question,
                    person: person,
                    facts: facts,
                    registerSample: sample
                )
                guard !Task.isCancelled else { return }
                draft = written
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - The user's own register

    /// The chat stores the register sample may be read from, in the order worth trying — or
    /// neither of them.
    ///
    /// Nothing is read at all unless the model that will see it runs on this Mac, or the user
    /// has opened the privacy switch for a cloud one (§7.5). `MessageDrafter` applies that same
    /// rule to the sample it is handed; this is the earlier half of it, so a store nobody may
    /// read is never even opened. A source switched off in Sources is left out here exactly as
    /// it is left out of a collection.
    private var sampleStores: (messages: MessagesCollector?, whatsapp: WhatsAppCollector?) {
        let tier = (try? model.makeProvider())?.spec.tier
        guard tier == .onDevice || model.shareSignals else { return (nil, nil) }
        let messages = MessagesCollector(userNames: model.sources.userNames)
        let whatsapp = WhatsAppCollector()
        return (
            model.sources.isEnabled(messages.id) ? messages : nil,
            model.sources.isEnabled(whatsapp.id) ? whatsapp : nil
        )
    }

    /// The user's own last messages to this person, newest first, or nothing at all.
    ///
    /// Messages first, WhatsApp second: whichever store this Mac can read, and whichever of the
    /// two the user and this person actually write in — a Mac with Messages ready but no iMessage
    /// history with them still learns the register from WhatsApp. A store that won't open (no
    /// Full Disk Access, not installed, a schema that has moved on) simply yields nothing, and
    /// the draft comes back in a neutral register: that is a far better answer to "write this
    /// message" than an error about a chat database.
    ///
    /// `nonisolated`, so it runs off the main actor: deciding a source's status opens its store,
    /// and reading the sample copies it.
    private nonisolated static func registerSample(
        for input: ProbeInput,
        from stores: (messages: MessagesCollector?, whatsapp: WhatsAppCollector?)
    ) async -> [String] {
        if let messages = stores.messages, messages.status() == .ready,
           let sample = try? await messages.registerSample(for: input), !sample.isEmpty {
            return sample
        }
        guard let whatsapp = stores.whatsapp, whatsapp.status() == .ready else { return [] }
        return (try? await whatsapp.registerSample(for: input)) ?? []
    }

    // MARK: - Handing it over

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    /// `imessage://<address>?body=…`, with the `sms:` form as the fallback for an address that
    /// won't sit in a URL — macOS routes both to whichever app handles messages.
    private var messagesURL: URL? {
        guard let recipient = phone.map(Self.dialable) ?? email else { return nil }
        let body = Self.encoded(draft)
        return URL(string: "imessage://\(recipient)?body=\(body)")
            ?? URL(string: "sms:\(Self.encoded(recipient))&body=\(body)")
    }

    /// WhatsApp wants the number in full international form without the `+`.
    private var whatsappURL: URL? {
        guard let phone else { return nil }
        let digits = phone.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return URL(string: "whatsapp://send?phone=\(digits)&text=\(Self.encoded(draft))")
    }

    /// A draft with nobody to address it to still opens Mail — `mailto:?body=` is a new message
    /// with the text in it and the To field left for the user.
    private var mailURL: URL? {
        URL(string: "mailto:\(email ?? "")?body=\(Self.encoded(draft))")
    }

    private var phone: String? {
        channels.first { $0.kind == .phone }?.value
    }

    private var email: String? {
        channels.first { $0.kind == .email }?.value.trimmingCharacters(in: .whitespaces)
    }

    /// Digits only, keeping a leading `+` so an international number still dials.
    private static func dialable(_ phone: String) -> String {
        let trimmed = phone.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.filter(\.isNumber)
        return trimmed.hasPrefix("+") ? "+" + digits : digits
    }

    /// Everything but the unreserved characters is escaped. A message is prose — it has `&`,
    /// `=`, `+`, `#` and line breaks in it, every one of which means something else inside a
    /// query string and would otherwise cut the draft short or split it into parameters.
    private static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
