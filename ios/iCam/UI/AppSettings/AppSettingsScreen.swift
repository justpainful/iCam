import SwiftUI

/// Everything that is *not* about the picture.
///
/// Kept strictly separate from Camera settings, so neither screen becomes the
/// place where everything ends up.
struct AppSettingsScreen: View {
    @ObservedObject var model: CameraViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var thermal: ThermalManager
    @EnvironmentObject private var battery: BatteryManager
    @EnvironmentObject private var storage: StorageMonitor
    @EnvironmentObject private var trust: TrustStore
    @EnvironmentObject private var link: PeerLink
    @Environment(\.dismiss) private var dismiss

    @State private var showsDiagnostics = false

    var body: some View {
        SettingsContainer(title: String(localized: "Settings"), onClose: { dismiss() }) {
            recordingSection
            connectionSection
            devicesSection
            powerSection
            storageSection
            privacySection
            aboutSection
        }
        .sheet(isPresented: $showsDiagnostics) {
            DiagnosticsScreen(model: model)
        }
    }

    // MARK: - Recording

    private var recordingSection: some View {
        SettingsSection(title: String(localized: "Recording"),
                        footer: String(localized: "Your iPhone always keeps the full-quality recording, even if the PC disconnects mid-take.")) {
            SegmentedChoice(title: String(localized: "Save recordings to"),
                            options: [(CaptureTarget.phone, String(localized: "iPhone")),
                                      (CaptureTarget.pc, String(localized: "PC")),
                                      (CaptureTarget.both, String(localized: "Both"))],
                            selection: $settings.recordingTarget)

            SettingRow(title: String(localized: "Record Audio")) {
                Toggle("", isOn: $settings.audioEnabled)
                    .labelsHidden()
                    .onChange(of: settings.audioEnabled) { _, enabled in
                        model.engine.enableAudio(enabled)
                    }
            }

            SettingRow(title: String(localized: "Add Photos to Library"),
                       subtitle: String(localized: "Also saves each photo to the iPhone Photos app.")) {
                Toggle("", isOn: $settings.savePhotosToLibrary).labelsHidden()
            }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        SettingsSection(title: String(localized: "Connection"),
                        footer: String(localized: "This is the quality your PC receives. It is separate from what your iPhone records.")) {
            SettingRow(title: String(localized: "Send to PC")) {
                Picker("", selection: $settings.streamProfileName) {
                    ForEach(AppSettings.streamProfiles, id: \.name) { entry in
                        Text(entry.name).tag(entry.name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            SettingRow(title: String(localized: "Send Microphone")) {
                Toggle("", isOn: $settings.sendMicrophoneToPC)
                    .labelsHidden()
                    .onChange(of: settings.sendMicrophoneToPC) { _, enabled in
                        model.audio.setEnabled(enabled && model.isStreaming)
                    }
            }

            SettingRow(title: String(localized: "Reconnect Automatically"),
                       subtitle: String(localized: "Rejoins a computer you have already paired with, without asking.")) {
                Toggle("", isOn: $settings.autoConnectToTrusted).labelsHidden()
            }
        }
    }

    // MARK: - Devices

    private var devicesSection: some View {
        SettingsSection(title: String(localized: "Devices"),
                        footer: trust.peers.isEmpty
                            ? String(localized: "Pair a computer from the connection button above the preview.")
                            : String(localized: "Forgetting a computer removes its access. You will need to pair again.")) {
            if trust.peers.isEmpty {
                Text(String(localized: "No paired computers"))
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.tertiaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(trust.peers) { peer in
                    SettingRow(title: peer.name,
                               subtitle: String(localized: "Paired \(peer.pairedAt.formatted(date: .abbreviated, time: .omitted))")) {
                        Button(String(localized: "Forget"), role: .destructive) {
                            if link.peerFingerprint == peer.id { link.disconnect() }
                            trust.forget(peer.id)
                        }
                        .font(.footnote)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Palette.record)
                    }
                }
            }
        }
    }

    // MARK: - Power

    private var powerSection: some View {
        SettingsSection(title: String(localized: "Power and Temperature"),
                        footer: String(localized: "iCam reports temperature as a state, not a number. iOS does not publish a temperature reading, so inventing one would be a guess.")) {
            SegmentedChoice(title: String(localized: "Quality Balance"),
                            options: [(ThermalManager.Mode.smart, String(localized: "Smart")),
                                      (ThermalManager.Mode.maximumQuality, String(localized: "Maximum"))],
                            selection: Binding(get: { thermal.mode },
                                               set: { thermal.mode = $0 }))

            Text(thermal.mode == .smart
                 ? String(localized: "iCam balances picture quality against how warm your iPhone gets.")
                 : String(localized: "iCam keeps your settings. Long 4K or high frame-rate sessions will run warm."))
                .font(.footnote)
                .foregroundStyle(Theme.Palette.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            SettingRow(title: String(localized: "Efficiency Mode"),
                       subtitle: String(localized: "For sessions that run for hours. Keeps the picture your PC sees, and stops everything that only exists on screen.")) {
                Toggle("", isOn: Binding(get: { thermal.efficiencyMode },
                                         set: { thermal.efficiencyMode = $0
                                                settings.efficiencyMode = $0 }))
                    .labelsHidden()
            }

            Button {
                dismiss()
                // Give the sheet time to leave before the screen goes dark,
                // otherwise the dismissal animation plays over black.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    model.isScreenOff = true
                }
            } label: {
                SettingRow(title: String(localized: "Display Off"),
                           subtitle: String(localized: "Keeps recording and streaming with the screen dark. Long-press the preview to do this without opening settings.")) {
                    Image(systemName: "moon.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.Palette.tertiaryLabel)
                }
            }
            .buttonStyle(.plain)

            SettingRow(title: String(localized: "Keep Screen Awake")) {
                Toggle("", isOn: $settings.keepScreenAwake)
                    .labelsHidden()
                    .onChange(of: settings.keepScreenAwake) { _, value in
                        UIApplication.shared.isIdleTimerDisabled = value
                    }
            }

            SettingRow(title: String(localized: "Battery")) {
                Text("\(Int(battery.level * 100))% · \(battery.source.displayName)")
                    .font(Theme.Typography.readout)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
            }

            SettingRow(title: String(localized: "Temperature")) {
                Text(thermal.level.displayName)
                    .font(Theme.Typography.readout)
                    .foregroundStyle(thermal.level > .warm ? Theme.Palette.warning
                                                           : Theme.Palette.secondaryLabel)
            }
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        SettingsSection(title: String(localized: "Storage")) {
            SettingRow(title: String(localized: "Available")) {
                Text(StorageMonitor.formatBytes(storage.freeBytes))
                    .font(Theme.Typography.readout)
                    .foregroundStyle(storage.isLow ? Theme.Palette.warning
                                                   : Theme.Palette.secondaryLabel)
            }

            SettingRow(title: String(localized: "Recording Time Left"),
                       subtitle: estimateSubtitle) {
                Text(StorageMonitor.formatDuration(
                    storage.estimatedSeconds(videoBitrate: masterBitrate)))
                    .font(Theme.Typography.readout)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
            }

            SettingRow(title: String(localized: "iCam Media")) {
                Text(StorageMonitor.formatBytes(RecoveryManager.totalRecordedBytes()))
                    .font(Theme.Typography.readout)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
            }
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        SettingsSection(title: String(localized: "Privacy"),
                        footer: String(localized: "iCam has no account, no cloud, and no analytics. Video and audio travel only between your iPhone and the computers you have paired with.")) {
            SettingRow(title: String(localized: "Haptics")) {
                Toggle("", isOn: $settings.hapticsEnabled).labelsHidden()
            }
            SettingRow(title: String(localized: "Developer Diagnostics"),
                       subtitle: String(localized: "Technical readouts. Off by default.")) {
                Toggle("", isOn: $settings.diagnosticsEnabled).labelsHidden()
            }
            if settings.diagnosticsEnabled {
                Button { showsDiagnostics = true } label: {
                    HStack {
                        Text(String(localized: "Open Diagnostics"))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(Theme.Palette.tertiaryLabel)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.label)
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        SettingsSection(title: String(localized: "About")) {
            SettingRow(title: String(localized: "Version")) {
                Text(Self.versionString)
                    .font(Theme.Typography.readout)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
            }
            SettingRow(title: String(localized: "Appearance")) {
                Picker("", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    // MARK: - Helpers

    private var masterBitrate: Int {
        RecordingEngine.recommendedBitrate(width: model.cameraState.width,
                                           height: model.cameraState.height,
                                           fps: model.cameraState.fps,
                                           codec: model.cameraState.codec)
    }

    private var estimateSubtitle: String {
        let resolution = Resolution(width: model.cameraState.width,
                                    height: model.cameraState.height).displayName
        return String(localized: "At \(resolution) \(model.cameraState.fps) fps \(model.cameraState.codec.displayName)")
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
