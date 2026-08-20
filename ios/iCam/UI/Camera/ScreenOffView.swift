import SwiftUI
import UIKit

/// Display Off.
///
/// For long webcam sessions, the screen is the single largest power draw on the
/// device and the one part nobody is looking at. This mode:
///
/// - removes the preview from the view hierarchy entirely, so the compositor
///   stops drawing camera frames — hiding it behind a black rectangle would
///   keep every one of those frames rendering;
/// - drops screen brightness to its floor, which on OLED with a black screen
///   is close to the panel being off;
/// - stops every timer that only exists to update something visible.
///
/// Capture, encoding, streaming and recording carry on untouched.
struct ScreenOffView: View {
    let peerName: String?
    let linkName: String
    let isStreaming: Bool
    let isRecording: Bool
    let elapsedUs: UInt64
    var onWake: () -> Void

    @State private var previousBrightness: CGFloat = UIScreen.main.brightness
    @State private var showsHint = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 18) {
                Text("iCam")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.30))

                if isRecording {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Theme.Palette.record.opacity(0.75))
                            .frame(width: 7, height: 7)
                        Text(formatElapsed(elapsedUs))
                            .font(.system(.footnote, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.42))
                    }
                } else if isStreaming {
                    Text(String(localized: "Streaming"))
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.32))
                }

                if let peerName {
                    Text("\(peerName) · \(linkName)")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.22))
                }

                if showsHint {
                    Text(String(localized: "Tap to wake"))
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.16))
                        .padding(.top, 26)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: wake)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            previousBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0.0
            // The hint has done its job after a few seconds; leaving it lit
            // costs pixels for no reason.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                withAnimation(.easeOut(duration: 0.6)) { showsHint = false }
            }
        }
        .onDisappear { UIScreen.main.brightness = previousBrightness }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Display off. iCam is still running. Double tap to wake."))
        .accessibilityAddTraits(.isButton)
    }

    private func wake() {
        UIScreen.main.brightness = previousBrightness
        Haptics.select()
        onWake()
    }
}
