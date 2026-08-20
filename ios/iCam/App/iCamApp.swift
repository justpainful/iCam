import SwiftUI
import AVFoundation
import UIKit

@main
struct iCamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .environmentObject(environment.settings)
                .environmentObject(environment.thermal)
                .environmentObject(environment.battery)
                .environmentObject(environment.storage)
                .environmentObject(environment.trustStore)
                .environmentObject(environment.discovery)
                .environmentObject(environment.link)
                .preferredColorScheme(environment.settings.appearance.colorScheme)
                .tint(Theme.Palette.label)
        }
        .onChange(of: scenePhase) { _, phase in
            environment.handle(scenePhase: phase)
        }
    }
}

/// The app delegate exists for exactly one reason: audio session configuration
/// has to happen before any capture starts, and it has to survive interruptions
/// that SwiftUI does not surface.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        configureAudioSession()
        return true
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.mixWithOthers` matters: a webcam that silences the user's music
            // or their conferencing app the moment iCam opens is a bad
            // neighbour. `.videoRecording` mode gets the microphone processing
            // Apple tunes for camera capture.
            try session.setCategory(.playAndRecord,
                                    mode: .videoRecording,
                                    options: [.mixWithOthers, .allowBluetooth,
                                              .defaultToSpeaker])
            try session.setActive(true, options: [])
        } catch {
            Log.app.error("Could not configure the audio session: \(String(describing: error))")
        }
    }
}

/// Decides what the user sees first, and nothing else.
struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            if settings.hasCompletedOnboarding {
                CameraScreen(model: environment.camera)
            } else {
                OnboardingView {
                    settings.hasCompletedOnboarding = true
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: settings.hasCompletedOnboarding)
    }
}
