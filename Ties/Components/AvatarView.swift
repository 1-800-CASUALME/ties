import AppKit
import SwiftUI

/// A contact's picture, the way Contacts.app draws one: the photo clipped to a circle, or,
/// when there is no photo, the person's initials in white on a gray gradient.
struct AvatarView: View {
    let data: Data?
    let name: String
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            if let image = photo {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color.gray.opacity(0.65), Color.gray],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Text(monogram)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        // The name is already spelled out next to every avatar we draw, so reading it twice
        // would only slow VoiceOver down.
        .accessibilityHidden(true)
    }

    private var photo: NSImage? {
        guard let data, !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    /// First letters of the given and family names — the first and last words of the display
    /// name — falling back to a single letter, then to "?" for a contact with no name at all.
    private var monogram: String {
        let words = name.split(whereSeparator: \.isWhitespace)
        guard let first = words.first?.first else { return "?" }
        guard words.count > 1, let last = words.last?.first else {
            return String(first).uppercased()
        }
        return (String(first) + String(last)).uppercased()
    }
}
