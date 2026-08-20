import SwiftUI

/// Developer Diagnostics.
///
/// Every technical number lives here and nowhere else, so the camera screen can
/// stay quiet. Nothing on this screen is shown to an ordinary user unless they
/// deliberately turn it on.
struct DiagnosticsScreen: View {
    @ObservedObject var model: CameraViewModel
    @EnvironmentObject private var link: PeerLink
    @EnvironmentObject private var thermal: ThermalManager
    @Environment(\.dismiss) private var dismiss

    @State private var tick = 0
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsContainer(title: String(localized: "Diagnostics"), onClose: { dismiss() }) {
            captureSection
            streamSection
            connectionSection
            budgetSection
        }
        .onReceive(refresh) { _ in tick &+= 1 }
    }

    private var captureSection: some View {
        SettingsSection(title: String(localized: "Capture")) {
            reading(String(localized: "Capture FPS"),
                    String(format: "%.1f", model.engine.measuredFps))
            reading(String(localized: "Dropped Frames"), "\(model.engine.droppedFrames)")
            reading(String(localized: "Format"),
                    "\(model.cameraState.width)×\(model.cameraState.height) @ \(model.cameraState.fps)")
            reading(String(localized: "Recorder Drops"), "\(model.recording.droppedFrames)")
        }
    }

    private var streamSection: some View {
        SettingsSection(title: String(localized: "Stream")) {
            let stats = model.stream.stats
            reading(String(localized: "Encoded FPS"), String(format: "%.1f", stats.fps))
            reading(String(localized: "Encoder Bitrate"),
                    "\(stats.bitrate / 1000) kbit/s")
            reading(String(localized: "Encoder Latency"),
                    "\(stats.latencyUs / 1000) ms")
            reading(String(localized: "Encoder Drops"), "\(stats.dropped)")
            reading(String(localized: "Output"),
                    "\(model.streamProfile.width)×\(model.streamProfile.height) @ \(model.streamProfile.fps) \(model.streamProfile.codec.displayName)")
        }
    }

    private var connectionSection: some View {
        SettingsSection(title: String(localized: "Connection")) {
            reading(String(localized: "Link"), link.link.displayName)
            reading(String(localized: "Round Trip"),
                    link.diagnostics.latencyUs > 0
                        ? "\(link.diagnostics.latencyUs * 2 / 1000) ms" : "—")
            reading(String(localized: "Clock Synchronised"),
                    link.diagnostics.isSynchronised ? String(localized: "Yes")
                                                    : String(localized: "No"))
            reading(String(localized: "Queued"), "\(link.diagnostics.pendingBytes) B")
            reading(String(localized: "Sent"),
                    StorageMonitor.formatBytes(link.diagnostics.bytesSent))
            reading(String(localized: "Transport Drops"), "\(link.diagnostics.droppedFrames)")
            if let fingerprint = link.peerFingerprint {
                reading(String(localized: "Peer Key"), String(fingerprint.prefix(16)))
            }
        }
    }

    private var budgetSection: some View {
        SettingsSection(title: String(localized: "Thermal Budget"),
                        footer: String(localized: "These are the allowances every subsystem reads instead of deciding for itself.")) {
            reading(String(localized: "Level"), thermal.level.displayName)
            reading(String(localized: "System Pressure"), "\(thermal.systemPressure.rawValue)")
            reading(String(localized: "Monitoring"),
                    String(format: "%.0f Hz", thermal.budget.monitoringHz))
            reading(String(localized: "Tracking"),
                    String(format: "%.0f Hz", thermal.budget.trackingHz))
            reading(String(localized: "PC Proxy"), "\(thermal.budget.pcProxyFps) fps")
            reading(String(localized: "Stream Ceiling"),
                    "\(thermal.budget.maxStreamBitrate / 1000) kbit/s")
            reading(String(localized: "GPU Effects"),
                    thermal.budget.allowsGpuEffects ? String(localized: "Allowed")
                                                    : String(localized: "Paused"))
        }
    }

    private func reading(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Theme.Palette.secondaryLabel)
            Spacer()
            Text(value)
                .font(Theme.Typography.readout)
                .foregroundStyle(Theme.Palette.label)
        }
    }
}
