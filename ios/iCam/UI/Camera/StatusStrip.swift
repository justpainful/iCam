import SwiftUI

/// The thin band above the preview.
///
/// It sits *beside* the picture, never on top of it, and it says as little as
/// possible: what is recording, what it is connected to, and — only while the
/// controls are up — the format. Anything more belongs in a settings screen.
struct StatusStrip: View {
    let recording: RecordingEngine.Status
    let connection: PeerLink.Status
    let link: Transport.Link
    let state: CameraState
    let batteryLevel: Double
    let thermalLevel: ThermalLevel
    let showsDetail: Bool

    var onTapConnection: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if recording.isRecording {
                RecordingChip(status: recording)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }

            Spacer(minLength: 0)

            if showsDetail {
                Text(formatSummary)
                    .font(Theme.Typography.readout)
                    .foregroundStyle(Theme.Palette.tertiaryLabel)
                    .transition(.opacity)
            }

            if thermalLevel > .warm {
                Label(thermalLevel.displayName, systemImage: "thermometer.medium")
                    .labelStyle(.iconOnly)
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.warning)
                    .accessibilityLabel(String(localized: "iPhone temperature: \(thermalLevel.displayName)"))
            }

            ConnectionChip(status: connection, link: link, action: onTapConnection)
        }
        .padding(.horizontal, Theme.Metrics.gutter)
        .frame(height: 30)
    }

    private var formatSummary: String {
        let resolution = Resolution(width: state.width, height: state.height).displayName
        return "\(resolution) · \(state.fps) · \(state.codec.displayName)"
    }
}

/// `● REC 00:04:18` plus, when the PC is involved, where it is landing.
private struct RecordingChip: View {
    let status: RecordingEngine.Status
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.Palette.record)
                .frame(width: 8, height: 8)
                .opacity(pulsing ? 0.35 : 1)
                .animation(reduceMotion ? nil
                                        : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                           value: pulsing)

            Text(formatElapsed(status.elapsedUs))
                .font(Theme.Typography.readoutStrong)
                .foregroundStyle(Theme.Palette.label)

            if status.target != .phone {
                Image(systemName: status.pcOk ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(status.pcOk ? Theme.Palette.connected : Theme.Palette.warning)
                    .accessibilityLabel(status.pcOk
                                        ? String(localized: "Also recording on PC")
                                        : String(localized: "PC recording interrupted; iPhone is still recording"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .icamGlassCapsule(tint: Theme.Palette.record.opacity(0.18))
        .onAppear { pulsing = true }
        .accessibilityElement(children: .combine)
    }
}

/// The only entry point to the connection flow on the main screen — one small
/// chip, tappable, that says exactly one thing.
private struct ConnectionChip: View {
    let status: PeerLink.Status
    let link: Transport.Link
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(Theme.Typography.readout)
                    .foregroundStyle(Theme.Palette.secondaryLabel)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .icamGlassCapsule(interactive: true)
        .accessibilityLabel(accessibilityText)
    }

    private var indicatorColor: Color {
        switch status {
        case .connected:   return Theme.Palette.connected
        case .connecting, .pairing: return Theme.Palette.warning
        case .failed:      return Theme.Palette.record
        case .disconnected: return Theme.Palette.tertiaryLabel
        }
    }

    private var title: String {
        switch status {
        case .connected(let name): return "\(name) · \(link.displayName)"
        case .connecting:          return String(localized: "Connecting")
        case .pairing:             return String(localized: "Pairing")
        case .failed:              return String(localized: "Reconnecting")
        case .disconnected:        return String(localized: "Connect")
        }
    }

    private var accessibilityText: String {
        switch status {
        case .connected(let name): return String(localized: "Connected to \(name). Open connection options.")
        default:                   return String(localized: "Connect to a computer")
        }
    }
}
