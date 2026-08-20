import SwiftUI

/// Liquid Glass where the system provides it, the system material where it does
/// not.
///
/// The rule iCam follows: glass is a **functional layer above camera content**,
/// used for the control bar, floating pills, and sheets. It is never spread
/// across the whole screen, and it never sits on top of the preview — the
/// preview has its own space, and the controls have theirs.
///
/// The `compiler(>=6.2)` guard is what lets one source tree build on both an
/// Xcode that has the Liquid Glass SDK and one that does not. The runtime
/// `#available` check is still required underneath it, because a binary built
/// with the new SDK still has to run on iOS 17 and 18.
struct ICamGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var shape: AnyShape
    var interactive: Bool
    var tint: Color?

    func body(content: Content) -> some View {
        if reduceTransparency {
            // Reduce Transparency is a legibility request, not a style
            // preference. Glass becomes an opaque surface of the same shape.
            content
                .background(shape.fill(tint ?? Theme.Palette.control))
                .overlay(shape.stroke(Theme.Palette.separatorStrong, lineWidth: 0.5))
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                content.glassEffect(liquidGlass, in: shape)
            } else {
                fallback(content)
            }
            #else
            fallback(content)
            #endif
        }
    }

    @ViewBuilder
    private func fallback(_ content: Content) -> some View {
        content
            .background(shape.fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
            .overlay(shape.fill(Color.black.opacity(0.28)))
            .overlay(shape.stroke(Theme.Palette.separator, lineWidth: 0.5))
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private var liquidGlass: Glass {
        var glass = Glass.regular
        if interactive { glass = glass.interactive() }
        if let tint { glass = glass.tint(tint) }
        return glass
    }
    #endif
}

extension View {
    /// Applies iCam's glass treatment in a given shape.
    func icamGlass<S: Shape>(in shape: S,
                             interactive: Bool = false,
                             tint: Color? = nil) -> some View {
        modifier(ICamGlass(shape: AnyShape(shape), interactive: interactive, tint: tint))
    }

    /// A capsule of glass — lens pills, the connection chip, the recording chip.
    func icamGlassCapsule(interactive: Bool = false, tint: Color? = nil) -> some View {
        icamGlass(in: Capsule(style: .continuous), interactive: interactive, tint: tint)
    }
}

/// Groups adjacent glass elements so the system can merge and morph them as one
/// piece, which is what makes Liquid Glass read as a material rather than as a
/// set of separately blurred rectangles.
struct ICamGlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
