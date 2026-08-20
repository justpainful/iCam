import SwiftUI

/// The square that appears where the user tapped to focus, then fades.
///
/// Deliberately close to the system camera's: this is a gesture people already
/// know, and inventing a different affordance for it would only be noise.
struct FocusIndicator: View {
    let point: CGPoint
    var onFinished: () -> Void

    @State private var scale: CGFloat = 1.35
    @State private var opacity: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let size: CGFloat = 74

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Color.yellow.opacity(0.95), lineWidth: 1.2)
            .frame(width: size, height: size)
            .overlay(alignment: .top) { tick.offset(y: -4) }
            .overlay(alignment: .bottom) { tick.offset(y: 4) }
            .overlay(alignment: .leading) { tick.rotationEffect(.degrees(90)).offset(x: -4) }
            .overlay(alignment: .trailing) { tick.rotationEffect(.degrees(90)).offset(x: 4) }
            .scaleEffect(scale)
            .opacity(opacity)
            .position(point)
            .allowsHitTesting(false)
            .onAppear(perform: animate)
    }

    private var tick: some View {
        Rectangle()
            .fill(Color.yellow.opacity(0.95))
            .frame(width: 1.2, height: 7)
    }

    private func animate() {
        if reduceMotion {
            opacity = 1
            scale = 1
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                scale = 1
                opacity = 1
            }
        }
        // Fade out on its own. A focus square that stays forever becomes
        // clutter on a screen whose whole job is to show the picture.
        withAnimation(.easeOut(duration: 0.4).delay(1.1)) { opacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { onFinished() }
    }
}
