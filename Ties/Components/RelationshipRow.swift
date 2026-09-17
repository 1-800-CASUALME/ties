import SwiftUI
import TiesCore

/// The relationship, as the Mac can see it (§4.5): when you last talked, which app you talked
/// in, and how much of it there has been over the past year.
///
/// None of this is research — it is counted from the message and mail stores on this Mac and
/// never leaves it. The bar is deliberately coarse: five steps, because the difference between
/// 40 and 60 messages is not something a user needs to read off a header.
struct RelationshipRow: View {
    let signals: LocalSignals

    /// The interaction counts each of the five segments stands for (§4.5). A count lights its
    /// own segment and every one below it.
    private static let steps = [0, 1, 5, 20, 100]
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "heart.text.square")
                .foregroundStyle(.secondary)
            Text(lastContact)
            if let channel {
                Image(systemName: channel.symbol)
                    .foregroundStyle(.secondary)
                    .help("Last talked in \(channel.name)")
                    .accessibilityLabel("In \(channel.name)")
            }
            strengthBar
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// "Talked 3 weeks ago", or what to say when the stores have nothing.
    private var lastContact: String {
        guard let date = signals.lastContact else { return "No messages yet" }
        return "Talked " + Self.relative.localizedString(for: date, relativeTo: .now)
    }

    private var strengthBar: some View {
        HStack(spacing: 2) {
            ForEach(Self.steps.indices, id: \.self) { index in
                Capsule()
                    .fill(index < lit ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 8, height: 4)
            }
        }
        .help(strengthHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strengthHelp)
    }

    /// How many segments are lit: one per step the count has reached, so silence lights one and
    /// a hundred messages lights all five.
    private var lit: Int {
        Self.steps.filter { signals.interactions >= $0 }.count
    }

    private var strengthHelp: String {
        signals.interactions == 1
            ? "1 message or mail in the past year"
            : "\(signals.interactions) messages and mails in the past year"
    }

    /// The app the last conversation most likely happened in, read off the order the collectors
    /// contributed: the first messaging source that touched this person wins. Contacts is not a
    /// channel — it never carried a conversation.
    private var channel: (symbol: String, name: String)? {
        for source in signals.sources {
            switch source {
            case "messages": return ("message.fill", "Messages")
            // The real WhatsApp icon belongs to the Sources screen, which has an app bundle to
            // take it from; a header row uses the symbol.
            case "whatsapp": return ("bubble.left.and.bubble.right.fill", "WhatsApp")
            case "mail": return ("envelope.fill", "Mail")
            default: continue
            }
        }
        return nil
    }
}
