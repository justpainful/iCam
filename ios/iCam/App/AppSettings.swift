import Foundation
import SwiftUI
import Combine

/// User preferences that are not camera settings.
///
/// Camera settings live in `CameraState`, because they belong to the hardware
/// and are shared with the PC. Everything here belongs to this iPhone and this
/// person: where files go, whether to reconnect, how the app behaves.
@MainActor
final class AppSettings: ObservableObject {

    enum Appearance: String, CaseIterable, Codable, Sendable {
        case system, light, dark

        var displayName: String {
            switch self {
            case .system: return String(localized: "System")
            case .light:  return String(localized: "Light")
            case .dark:   return String(localized: "Dark")
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light:  return .light
            case .dark:   return .dark
            }
        }
    }

    // Recording
    @AppStorage("recording.target") var recordingTarget: CaptureTarget = .phone
    @AppStorage("recording.audioEnabled") var audioEnabled = true
    @AppStorage("recording.saveToPhotos") var savePhotosToLibrary = true
    @AppStorage("recording.saveVideosToPhotos") var saveVideosToLibrary = false

    // Connection
    @AppStorage("connection.autoConnect") var autoConnectToTrusted = true
    @AppStorage("connection.streamProfileName") var streamProfileName = "1080p30"
    @AppStorage("connection.microphoneToPC") var sendMicrophoneToPC = true

    // Behaviour
    @AppStorage("app.hapticsEnabled") var hapticsEnabled = true { didSet { Haptics.isEnabled = hapticsEnabled } }
    @AppStorage("app.keepScreenAwake") var keepScreenAwake = true
    @AppStorage("app.appearance") var appearance: Appearance = .dark
    @AppStorage("app.thermalMode") var thermalMode: ThermalManager.Mode = .smart
    @AppStorage("app.efficiencyMode") var efficiencyMode = false
    @AppStorage("app.hasCompletedOnboarding") var hasCompletedOnboarding = false

    /// The preview's share of the screen, so it survives relaunch.
    @AppStorage("ui.previewHeightFraction") var previewHeightFraction: Double = 0.72
    @AppStorage("ui.previewFills") var previewFills = false

    // Developer
    @AppStorage("developer.diagnosticsEnabled") var diagnosticsEnabled = false

    init() {
        Haptics.isEnabled = hapticsEnabled
    }

    /// The stream profiles offered in Connection settings. Named rather than
    /// numeric so the stored value survives a change to the numbers.
    static let streamProfiles: [(name: String, profile: StreamProfile)] = [
        ("720p30",  .webcam720p30),
        ("1080p30", .webcam1080p30),
        ("1080p60", .webcam1080p60)
    ]

    var streamProfile: StreamProfile {
        Self.streamProfiles.first { $0.name == streamProfileName }?.profile ?? .webcam1080p30
    }
}
