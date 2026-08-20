import SwiftUI

/// The bottom control area.
///
/// Five controls, in their own space below the preview — never over it. The
/// deck has weight and depth so it reads as the instrument panel of a camera,
/// but it stays dark enough that the picture above it is always the brightest
/// thing on screen.
struct ControlDeck: View {
    let lenses: [LensOption]
    let state: CameraState
    let isRecording: Bool
    let isBusy: Bool

    var onCameraSettings: () -> Void
    var onCapturePhoto: () -> Void
    var onToggleRecording: () -> Void
    var onSwitchCamera: () -> Void
    var onAppSettings: () -> Void
    var onSelectLens: (LensOption) -> Void
    var onToggleLensLock: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            LensSelector(lenses: lenses,
                         activeLensId: state.lensId,
                         zoom: state.zoom,
                         isLocked: state.lensLocked,
                         onSelect: onSelectLens,
                         onToggleLock: onToggleLensLock)

            HStack(spacing: 0) {
                DeckButton(symbol: "camera.aperture",
                           label: String(localized: "Camera"),
                           action: onCameraSettings)

                Spacer(minLength: 0)

                ShutterButton(action: onCapturePhoto, isEnabled: !isBusy)

                Spacer(minLength: 0)

                RecordButton(isRecording: isRecording, action: onToggleRecording)

                Spacer(minLength: 0)

                DeckButton(symbol: "arrow.trianglehead.2.clockwise.rotate.90.camera",
                           fallbackSymbol: "arrow.triangle.2.circlepath.camera",
                           label: String(localized: "Switch"),
                           action: onSwitchCamera)

                Spacer(minLength: 0)

                DeckButton(symbol: "slider.horizontal.3",
                           label: String(localized: "Settings"),
                           action: onAppSettings)
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Buttons

/// A secondary control: icon over a small label, generous touch target.
private struct DeckButton: View {
    let symbol: String
    var fallbackSymbol: String?
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: resolvedSymbol)
                    .font(.system(size: 19, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: 22)
                Text(label)
                    .font(Theme.Typography.controlLabel)
            }
            .foregroundStyle(Theme.Palette.secondaryLabel)
            .frame(width: 62, height: Theme.Metrics.minimumTouchTarget + 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(DeckButtonStyle())
        .accessibilityLabel(label)
    }

    /// Newer SF Symbols are not present on older systems, and asking for one
    /// that does not exist draws nothing at all.
    private var resolvedSymbol: String {
        guard let fallbackSymbol else { return symbol }
        return UIImage(systemName: symbol) != nil ? symbol : fallbackSymbol
    }
}

private struct DeckButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : Theme.Motion.interactive, value: configuration.isPressed)
    }
}

/// The photo button. A ring with a filled centre — the shape every iPhone
/// owner already reads as "take a picture".
private struct ShutterButton: View {
    let action: () -> Void
    let isEnabled: Bool

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Theme.Palette.label.opacity(0.9), lineWidth: 2.5)
                    .frame(width: 58, height: 58)
                Circle()
                    .fill(Theme.Palette.label)
                    .frame(width: 47, height: 47)
            }
            .frame(width: 66, height: 66)
            .contentShape(Circle())
        }
        .buttonStyle(ShutterButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(String(localized: "Take Photo"))
    }
}

private struct ShutterButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .animation(reduceMotion ? nil : Theme.Motion.interactive, value: configuration.isPressed)
    }
}

/// The record button. Morphs between a circle and a rounded square — the one
/// piece of motion on this screen that carries meaning rather than decoration.
private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Theme.Palette.label.opacity(0.28), lineWidth: 2)
                    .frame(width: 52, height: 52)
                RoundedRectangle(cornerRadius: isRecording ? 6 : 20, style: .continuous)
                    .fill(Theme.Palette.record)
                    .frame(width: isRecording ? 22 : 40, height: isRecording ? 22 : 40)
            }
            .frame(width: 60, height: 60)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : Theme.Motion.control, value: isRecording)
        .accessibilityLabel(isRecording
                            ? String(localized: "Stop Recording")
                            : String(localized: "Start Recording"))
    }
}
