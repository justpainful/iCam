import Foundation
import UIKit
import Combine

/// Battery level and power source.
///
/// USB connectivity charges the phone, but charging is not the same as running
/// cool — a charging iPhone shooting 4K60 can get hotter than a discharging one.
/// So this reports facts and `ThermalManager` decides; nothing here assumes
/// "plugged in" means "unlimited".
@MainActor
final class BatteryManager: ObservableObject {

    enum PowerSource: String, Sendable {
        case battery, usb, wireless

        var displayName: String {
            switch self {
            case .battery:  return String(localized: "Battery")
            case .usb:      return String(localized: "USB")
            case .wireless: return String(localized: "Wireless")
            }
        }
    }

    @Published private(set) var level: Double = 1.0
    @Published private(set) var source: PowerSource = .battery
    @Published private(set) var isLowPowerMode = false

    private var observers: [NSObjectProtocol] = []

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIDevice.batteryLevelDidChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(center.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }

    deinit {
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
    }

    /// True when the user should be warned before starting a long session.
    var isLow: Bool { level < 0.15 && source == .battery }

    private func refresh() {
        let device = UIDevice.current
        // `batteryLevel` is -1 while monitoring is warming up. Reporting -100%
        // would be worse than reporting the previous value.
        if device.batteryLevel >= 0 { level = Double(device.batteryLevel) }

        switch device.batteryState {
        case .charging, .full:
            // iOS does not distinguish the connector, so wireless is inferred
            // only from what we can actually observe. When in doubt, say USB.
            source = .usb
        case .unplugged, .unknown:
            source = .battery
        @unknown default:
            source = .battery
        }

        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}
