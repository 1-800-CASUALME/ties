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

    /// Asks the provider for a draft. The register sample §7.4 describes — the user's own last
    /// messages to this person — is deliberately empty: `TiesCore` has no API for reading it
    /// yet, so the draft comes back in a neutral register rather than the user's own.
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
        task = model.track {
            do {
                let written = try await drafter.draft(
                    need: question,
                    person: person,
                    facts: facts,
                    registerSample: []
                )
                guard !Task.isCancelled else { return }
                draft = written
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            drafting = false
        }
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
