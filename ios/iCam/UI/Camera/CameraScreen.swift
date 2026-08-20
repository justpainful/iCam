import SwiftUI
import AVFoundation

/// The whole app, as far as most people are concerned.
///
/// One screen: a large preview, and a small deck of controls beneath it. The
/// controls never sit on the picture — they have their own space, and the
/// divider between them can be dragged to give either one more room.
struct CameraScreen: View {

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var thermal: ThermalManager
    @EnvironmentObject private var battery: BatteryManager
    @EnvironmentObject private var link: PeerLink
    @ObservedObject var model: CameraViewModel

    @State private var showsCameraSettings = false
    @State private var showsAppSettings = false
    @State private var showsConnect = false
    @State private var dragOffset: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Bounds for the preview's share of the screen. The lower bound still
    /// leaves a usable picture; the upper bound still leaves the deck reachable.
    private let minimumFraction: Double = 0.42
    private let maximumFraction: Double = 0.86

    var body: some View {
        content
            .overlay {
                if model.isScreenOff {
                    ScreenOffView(peerName: link.peerName,
                                  linkName: link.link.displayName,
                                  isStreaming: model.isStreaming,
                                  isRecording: model.recording.isRecording,
                                  elapsedUs: model.recording.elapsedUs,
                                  onWake: { model.isScreenOff = false })
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.isScreenOff)
    }

    private var content: some View {
        GeometryReader { geometry in
            let available = geometry.size.height
            let previewHeight = clampedPreviewHeight(in: available)

            VStack(spacing: 0) {
                StatusStrip(recording: model.recording,
                            connection: link.status,
                            link: link.link,
                            state: model.cameraState,
                            batteryLevel: battery.level,
                            thermalLevel: thermal.level,
                            showsDetail: model.controlsVisible,
                            onTapConnection: { showsConnect = true })

                // While the display is off the preview is removed from the
                // hierarchy rather than covered, so the compositor stops
                // drawing camera frames entirely.
                if model.isScreenOff {
                    Color.black.frame(height: previewHeight)
                } else {
                    previewArea(height: previewHeight)
                }

                ResizeHandle(isDragging: dragOffset != 0)
                    .gesture(resizeGesture(available: available))

                ControlDeck(lenses: model.lenses,
                            state: model.cameraState,
                            isRecording: model.recording.isRecording,
                            isBusy: !model.isSessionRunning,
                            onCameraSettings: { showsCameraSettings = true },
                            onCapturePhoto: model.capturePhoto,
                            onToggleRecording: model.toggleRecording,
                            onSwitchCamera: model.toggleFrontBack,
                            onAppSettings: { showsAppSettings = true },
                            onSelectLens: model.selectLens,
                            onToggleLensLock: toggleLensLock)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.Palette.background.ignoresSafeArea())
        .overlay(alignment: .top) { noticeBanner }
        .sheet(isPresented: $showsCameraSettings) {
            CameraSettingsScreen(model: model)
        }
        .sheet(isPresented: $showsAppSettings) {
            AppSettingsScreen(model: model)
        }
        .sheet(isPresented: $showsConnect) {
            ConnectSheet()
        }
        .alert(item: $model.error) { error in
            Alert(title: Text(error.title),
                  message: Text(error.message),
                  dismissButton: .default(Text(String(localized: "OK"))))
        }
        .statusBarHidden(false)
        .onAppear { model.onAppear() }
        .onDisappear { model.onDisappear() }
    }

    // MARK: - Preview

    private func previewArea(height: CGFloat) -> some View {
        ZStack {
            CameraPreviewView(session: model.engine.session,
                              fills: settings.previewFills,
                              rotationAngle: model.currentRotationAngle,
                              onFocusTap: { previewPoint, devicePoint in
                                  model.focusAndExpose(previewPoint: previewPoint,
                                                       devicePoint: devicePoint)
                              },
                              onZoom: { model.setZoom($0) },
                              onZoomEnded: { model.showControls() },
                              onDoubleTap: { settings.previewFills.toggle() })

            if let indicator = model.focusIndicator {
                FocusIndicator(point: indicator.point) { model.focusIndicator = nil }
                    .id(indicator.id)
            }

            // Confirmation that the sensor actually fired, timed off the
            // capture callback rather than off the button press.
            if model.shutterFlash {
                Rectangle().fill(Color.white).allowsHitTesting(false)
            }

            if let message = model.interruptionMessage {
                InterruptionOverlay(message: message)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.showControls() }
        .onLongPressGesture(minimumDuration: 0.7) {
            Haptics.lock()
            model.isScreenOff = true
        }
        .accessibilityAction(named: Text(String(localized: "Turn Display Off"))) {
            model.isScreenOff = true
        }
    }

    // MARK: - Resizing

    private func clampedPreviewHeight(in available: CGFloat) -> CGFloat {
        let fraction = (settings.previewHeightFraction + Double(dragOffset / max(available, 1)))
            .clamped(to: minimumFraction ... maximumFraction)
        return available * fraction
    }

    private func resizeGesture(available: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let fraction = (settings.previewHeightFraction
                                + Double(value.translation.height / max(available, 1)))
                    .clamped(to: minimumFraction ... maximumFraction)
                settings.previewHeightFraction = fraction
                dragOffset = 0
                Haptics.select()
            }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = thermal.notice {
            NoticeBanner(title: notice.title, message: notice.message) {
                thermal.dismissNotice()
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(reduceMotion ? nil : Theme.Motion.control, value: notice.id)
        }
    }

    private func toggleLensLock() {
        var mutation = CameraMutation()
        mutation.lensLocked = !model.cameraState.lensLocked
        model.apply(mutation)
        Haptics.lock()
    }
}

// MARK: - Supporting views

/// The grabber between the preview and the deck. Small, but it is the only
/// affordance telling the user the split is theirs to set.
private struct ResizeHandle: View {
    let isDragging: Bool

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(isDragging ? Theme.Palette.secondaryLabel : Theme.Palette.separatorStrong)
                .frame(width: 38, height: 4)
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .accessibilityLabel(String(localized: "Resize preview"))
        .accessibilityHint(String(localized: "Drag up or down to change how much room the preview gets."))
    }
}

/// Shown over the preview when the system takes the camera away. Explains, in a
/// sentence, and never shows an `AVError` number.
private struct InterruptionOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
            VStack(spacing: 10) {
                Image(systemName: "camera.metering.none")
                    .font(.title2)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Palette.label)
                    .padding(.horizontal, 32)
            }
        }
        .transition(.opacity)
    }
}

/// A plain-language note about something iCam changed on its own.
private struct NoticeBanner: View {
    let title: String
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Palette.label)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Palette.tertiaryLabel)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Dismiss"))
        }
        .padding(14)
        .icamGlass(in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))
        .padding(.top, 6)
    }
}

extension ICamError: Identifiable {
    public var id: String { code + (detail ?? "") }
}
