import SwiftUI

/// How far through a linear flow the user is: one small dot per step, the current one tinted and
/// slightly larger, the ones behind it half-tinted because they are done.
///
/// The dots are also the way around the flow. Each is a button that says where it goes on hover
/// and jumps there when clicked — someone who wants to skip straight to the end, or go back and
/// look at something, shouldn't have to sit through the step they are on.
struct StepDots: View {
    let count: Int
    let current: Int
    /// One name per step, in order, for the tooltips. Short of `count` names, the extra dots fall
    /// back to their number.
    var names: [String] = []
    var onSelect: (Int) -> Void = { _ in }

    @State private var hovered: Int?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                Button { onSelect(index) } label: {
                    Circle()
                        .fill(fill(index))
                        .frame(width: 6, height: 6)
                        .scaleEffect(scale(index))
                        // The dot is 6pt across; the button around it is a real target.
                        .frame(width: 14, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    withAnimation(.snappy) {
                        if inside {
                            hovered = index
                        } else if hovered == index {
                            hovered = nil
                        }
                    }
                }
                .help(name(index))
                .accessibilityLabel("\(name(index)), step \(index + 1) of \(count)")
            }
        }
        .animation(.snappy, value: current)
    }

    private func fill(_ index: Int) -> AnyShapeStyle {
        if index == current { return AnyShapeStyle(.tint) }
        // Behind the current step: done, and worth telling apart from what is still to come.
        if index < current { return AnyShapeStyle(Color.accentColor.opacity(0.5)) }
        return AnyShapeStyle(.tertiary)
    }

    private func scale(_ index: Int) -> Double {
        if hovered == index { return 1.6 }
        return index == current ? 1.3 : 1
    }

    private func name(_ index: Int) -> String {
        index < names.count ? names[index] : "Step \(index + 1)"
    }
}
