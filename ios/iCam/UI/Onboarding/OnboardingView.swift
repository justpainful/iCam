import SwiftUI
import AVFoundation

/// Two pages, then the camera.
///
/// No tour, no feature list, no permission wall. Camera access is requested
/// here because the next thing that happens is a camera; everything else is
/// asked for at the moment it is actually needed.
struct OnboardingView: View {
    var onFinished: () -> Void

    @State private var page = 0
    @State private var isRequestingAccess = false

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Group {
                    if page == 0 { firstPage } else { secondPage }
                }
                .transition(.opacity)

                Spacer()

                PageDots(count: 2, index: page)
                    .padding(.bottom, 28)

                Button(page == 0 ? String(localized: "Continue") : String(localized: "Start")) {
                    if page == 0 {
                        withAnimation(Theme.Motion.control) { page = 1 }
                    } else {
                        requestCameraAccess()
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isRequestingAccess)
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var firstPage: some View {
        VStack(spacing: 14) {
            Image("AppIconArtwork")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.bottom, 10)

            Text("iCam")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.Palette.label)

            VStack(spacing: 2) {
                Text(String(localized: "Your iPhone."))
                Text(String(localized: "Your camera."))
                Text(String(localized: "Everywhere."))
            }
            .font(.title3)
            .foregroundStyle(Theme.Palette.secondaryLabel)
        }
    }

    private var secondPage: some View {
        VStack(spacing: 18) {
            Image(systemName: "iphone.gen3.badge.play")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Theme.Palette.label)
                .padding(.bottom, 6)

            Text(String(localized: "Use iCam as a camera,\nor connect it to your PC."))
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Palette.label)

            Text(String(localized: "Everything works without a computer. Connecting one is an extra, not a requirement."))
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Palette.tertiaryLabel)
                .padding(.horizontal, 44)
        }
    }

    private func requestCameraAccess() {
        isRequestingAccess = true
        AVCaptureDevice.requestAccess(for: .video) { _ in
            // Whatever the answer, the app opens. A refusal is explained on the
            // camera screen, where it is relevant, rather than blocking here.
            DispatchQueue.main.async {
                isRequestingAccess = false
                onFinished()
            }
        }
    }
}

private struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0 ..< count, id: \.self) { i in
                Circle()
                    .fill(i == index ? Theme.Palette.label : Theme.Palette.separatorStrong)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}
