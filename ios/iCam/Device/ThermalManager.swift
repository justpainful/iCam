import Foundation
import AVFoundation
import UIKit
import Combine

enum ThermalLevel: String, Codable, Sendable, Comparable {
    case normal, warm, hot, critical

    private var order: Int {
        switch self {
        case .normal: return 0
        case .warm: return 1
        case .hot: return 2
        case .critical: return 3
        }
    }

    static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.order < b.order }

    /// What the user sees. Never a number, because iOS gives us no temperature
    /// to be honest about.
    var displayName: String {
        switch self {
        case .normal:   return String(localized: "Normal")
        case .warm:     return String(localized: "Warm")
        case .hot:      return String(localized: "Elevated")
        case .critical: return String(localized: "High")
        }
    }

    /// The string that crosses the wire.
    var wireValue: String {
        switch self {
        case .normal: return "normal"
        case .warm: return "elevated"
        case .hot: return "high"
        case .critical: return "critical"
        }
    }
}

/// Concrete allowances every subsystem reads instead of deciding for itself.
///
/// Having one budget rather than scattered `if thermalState == .serious` checks
/// is what makes the degradation order predictable and testable.
struct ThermalBudget: Equatable, Sendable {
    /// Refresh rate for histogram, zebra, false colour.
    var monitoringHz: Double
    /// Vision subject tracking rate.
    var trackingHz: Double
    /// Local preview downscale, 1.0 = native.
    var previewScale: Double
    /// Frame rate of the low-cost proxy the PC control window shows.
    var pcProxyFps: Int
    /// GPU effects: background replacement, focus peaking overlay.
    var allowsGpuEffects: Bool
    /// Ceiling for the webcam stream, in bits per second.
    var maxStreamBitrate: Int
    /// Ceiling for the webcam stream's pixel count. Only touched at critical.
    var maxStreamPixels: Int
    var uiAnimationsEnabled: Bool

    static let full = ThermalBudget(monitoringHz: 12, trackingHz: 15, previewScale: 1.0,
                                    pcProxyFps: 30, allowsGpuEffects: true,
                                    maxStreamBitrate: 20_000_000,
                                    maxStreamPixels: 3840 * 2160,
                                    uiAnimationsEnabled: true)

    static let warm = ThermalBudget(monitoringHz: 6, trackingHz: 8, previewScale: 1.0,
                                    pcProxyFps: 20, allowsGpuEffects: true,
                                    maxStreamBitrate: 12_000_000,
                                    maxStreamPixels: 1920 * 1080,
                                    uiAnimationsEnabled: true)

    static let hot = ThermalBudget(monitoringHz: 2, trackingHz: 3, previewScale: 0.75,
                                   pcProxyFps: 12, allowsGpuEffects: false,
                                   maxStreamBitrate: 6_000_000,
                                   maxStreamPixels: 1920 * 1080,
                                   uiAnimationsEnabled: false)

    static let critical = ThermalBudget(monitoringHz: 0, trackingHz: 0, previewScale: 0.5,
                                        pcProxyFps: 6, allowsGpuEffects: false,
                                        maxStreamBitrate: 3_000_000,
                                        maxStreamPixels: 1280 * 720,
                                        uiAnimationsEnabled: false)

    /// Efficiency Mode is a *floor*, not a punishment: the stream stays at a
    /// good bitrate, and only the things nobody is looking at get cheaper.
    func applyingEfficiencyMode() -> ThermalBudget {
        var b = self
        b.monitoringHz = min(b.monitoringHz, 2)
        b.trackingHz = min(b.trackingHz, 3)
        b.pcProxyFps = min(b.pcProxyFps, 10)
        b.previewScale = min(b.previewScale, 0.75)
        b.allowsGpuEffects = false
        b.uiAnimationsEnabled = false
        return b
    }
}

/// A plain-language note about something iCam changed on its own.
struct ThermalNotice: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}

/// Watches every heat-relevant signal and publishes one level and one budget.
///
/// This exists from the first commit rather than being retrofitted, because a
/// camera app that gets hot is a camera app that stops recording.
@MainActor
final class ThermalManager: ObservableObject {

    @Published private(set) var level: ThermalLevel = .normal
    @Published private(set) var budget: ThermalBudget = .full
    @Published private(set) var systemPressure: AVCaptureDevice.SystemPressureState.Level = .nominal
    @Published private(set) var notice: ThermalNotice?

    /// `Smart` balances quality against heat. `Maximum Quality` keeps the
    /// requested settings until the system itself intervenes.
    @Published var mode: Mode = .smart { didSet { recompute() } }
    @Published var efficiencyMode = false { didSet { recompute() } }

    enum Mode: String, Codable, CaseIterable, Sendable {
        case smart, maximumQuality

        var displayName: String {
            switch self {
            case .smart:          return String(localized: "Smart")
            case .maximumQuality: return String(localized: "Maximum Quality")
            }
        }
    }

    /// Fires whenever the budget changes, so subsystems can react without
    /// polling. Called on the main actor.
    var onBudgetChange: ((ThermalBudget) -> Void)?

    private var thermalObserver: NSObjectProtocol?
    private var lastAnnouncedLevel: ThermalLevel = .normal
    /// Hysteresis: recovery needs to hold, or the app oscillates between
    /// quality levels and the user sees the picture pumping.
    private var levelSince = Date()
    private let recoveryHoldSeconds: TimeInterval = 20

    init() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.recompute() }
            }
        recompute()
    }

    deinit {
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
    }

    func update(systemPressure newValue: AVCaptureDevice.SystemPressureState.Level) {
        guard newValue != systemPressure else { return }
        systemPressure = newValue
        recompute()
    }

    func dismissNotice() { notice = nil }

    // MARK: - The rule

    private func recompute() {
        let processLevel: ThermalLevel = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal:  return .normal
            case .fair:     return .warm
            case .serious:  return .hot
            case .critical: return .critical
            @unknown default: return .warm
            }
        }()

        let pressureLevel: ThermalLevel = {
            switch systemPressure {
            case .nominal:  return .normal
            case .fair:     return .warm
            case .serious:  return .hot
            case .critical, .shutdown: return .critical
            default:        return .normal
            }
        }()

        // The worse of the two wins. `systemPressure` reacts to what the camera
        // itself is doing and often moves first; `thermalState` reflects the
        // whole device. Ignoring either one loses a real signal.
        var target = max(processLevel, pressureLevel)

        // Coming back down has to be earned. Going up is immediate.
        if target < level, Date().timeIntervalSince(levelSince) < recoveryHoldSeconds {
            target = level
        }

        if target != level {
            level = target
            levelSince = Date()
        }

        var next: ThermalBudget
        switch (mode, level) {
        case (.maximumQuality, .normal), (.maximumQuality, .warm):
            // Maximum Quality means the user accepted the heat. iCam still
            // stops decorating, but it does not touch their picture.
            next = .full
        case (_, .normal):   next = .full
        case (_, .warm):     next = .warm
        case (_, .hot):      next = .hot
        case (_, .critical): next = .critical
        }

        if efficiencyMode { next = next.applyingEfficiencyMode() }

        if next != budget {
            budget = next
            onBudgetChange?(next)
        }

        announceIfNeeded()
    }

    /// iCam never silently lowers quality. Every automatic change gets one
    /// short, non-technical sentence — and only when the level actually rises.
    private func announceIfNeeded() {
        guard level != lastAnnouncedLevel else { return }
        let rising = level > lastAnnouncedLevel
        lastAnnouncedLevel = level
        guard rising else {
            notice = nil
            return
        }

        switch level {
        case .normal:
            notice = nil
        case .warm:
            // Not worth interrupting anyone over.
            notice = nil
        case .hot:
            notice = ThermalNotice(
                title: String(localized: "iPhone temperature is elevated"),
                message: String(localized: "Monitoring quality was reduced to keep recording stable."))
        case .critical:
            notice = ThermalNotice(
                title: String(localized: "iPhone is running hot"),
                message: String(localized: "iCam lowered the stream sent to your PC. Your recording on iPhone is unchanged."))
        }
        Log.thermal.notice("Thermal level is now \(self.level.rawValue, privacy: .public)")
    }
}
