import SwiftUI

/// The whole visual vocabulary, in one place.
///
/// iCam is near-black, quiet, and built out of spacing rather than decoration.
/// The preview is the brightest thing on screen at all times; every surface
/// here is chosen to sit *under* it, never to compete with it.
enum Theme {

    // MARK: Colour

    enum Palette {
        /// The app background. Genuinely black, so an OLED iPhone lights only
        /// the preview and the controls — which is also the single largest
        /// power saving available on a camera screen.
        static let background = Color.black

        /// The control area below the preview. Barely lifted off black.
        static let surface = Color(white: 0.055)
        /// A control sitting on the surface.
        static let control = Color(white: 0.11)
        /// A control that is currently on.
        static let controlActive = Color(white: 0.19)

        static let separator = Color.white.opacity(0.08)
        static let separatorStrong = Color.white.opacity(0.14)

        static let label = Color.white
        static let secondaryLabel = Color.white.opacity(0.55)
        static let tertiaryLabel = Color.white.opacity(0.32)

        /// The one saturated colour in the product. Reserved for recording.
        static let record = Color(red: 1.0, green: 0.23, blue: 0.19)
        static let connected = Color(red: 0.20, green: 0.78, blue: 0.35)
        static let warning = Color(red: 1.0, green: 0.72, blue: 0.20)
    }

    // MARK: Metrics

    enum Metrics {
        static let cornerRadius: CGFloat = 14
        static let controlCornerRadius: CGFloat = 12
        static let pillCornerRadius: CGFloat = 22

        /// Every tappable control is at least this tall.
        static let minimumTouchTarget: CGFloat = 44

        static let barHeight: CGFloat = 92
        static let gutter: CGFloat = 16
        static let tightGutter: CGFloat = 10
    }

    // MARK: Type

    enum Typography {
        /// Numbers that change while the user watches — the recording timer,
        /// ISO, shutter. Monospaced digits stop the layout from twitching.
        static let readout = Font.system(.footnote, design: .rounded).monospacedDigit()
        static let readoutStrong = Font.system(.subheadline, design: .rounded)
            .monospacedDigit().weight(.semibold)
        static let controlLabel = Font.system(.caption2, design: .rounded).weight(.medium)
        static let sectionTitle = Font.system(.footnote).weight(.semibold)
    }

    // MARK: Motion

    enum Motion {
        /// Controls appearing and disappearing.
        static let control = Animation.spring(response: 0.32, dampingFraction: 0.86)
        /// Anything the finger is directly driving.
        static let interactive = Animation.interactiveSpring(response: 0.24,
                                                             dampingFraction: 0.85)
        /// State that changed on its own, away from the finger.
        static let ambient = Animation.easeInOut(duration: 0.22)

        /// Honours Reduce Motion, and the thermal budget: when the phone is
        /// working hard, decoration is the first thing to go.
        static func respecting(reduceMotion: Bool, animationsAllowed: Bool,
                               _ animation: Animation) -> Animation? {
            (reduceMotion || !animationsAllowed) ? nil : animation
        }
    }
}

// MARK: - Surfaces

/// The material used for the control area and for panels.
///
/// On iOS 26 this is real Liquid Glass. Below that it is the system material
/// that the same design was built around — not a stripped-down version, and not
/// a hand-rolled imitation.
struct PanelBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat = Theme.Metrics.cornerRadius
    var elevated = false

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(elevated ? Theme.Palette.control : Theme.Palette.surface))
        } else {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.black.opacity(elevated ? 0.35 : 0.55)))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Theme.Palette.separator, lineWidth: 0.5)))
        }
    }
}

extension View {
    func panelBackground(cornerRadius: CGFloat = Theme.Metrics.cornerRadius,
                         elevated: Bool = false) -> some View {
        modifier(PanelBackground(cornerRadius: cornerRadius, elevated: elevated))
    }

    /// A hairline, drawn at true pixel width rather than at a point.
    func hairline(edge: Edge.Set = .top) -> some View {
        overlay(alignment: edge == .top ? .top : .bottom) {
            Rectangle()
                .fill(Theme.Palette.separator)
                .frame(height: 1 / UIScreen.main.scale)
        }
    }
}
