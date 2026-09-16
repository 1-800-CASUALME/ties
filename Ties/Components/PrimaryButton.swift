import SwiftUI

/// The one prominent action on a screen. Always the default button, so Return triggers
/// whichever screen the wizard is showing without any key handling of its own.
struct PrimaryButton: View {
    private let title: String
    private let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }
}
