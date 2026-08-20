import SwiftUI
import Network

/// Finding, pairing with, and disconnecting from a computer.
///
/// Reached from one small chip above the preview, so the main screen carries
/// none of this. Local network permission is requested here, at the moment the
/// user asked for it — never on first launch.
struct ConnectSheet: View {
    @EnvironmentObject private var discovery: Discovery
    @EnvironmentObject private var link: PeerLink
    @EnvironmentObject private var trust: TrustStore
    @Environment(\.dismiss) private var dismiss

    @State private var manualHost = ""
    @State private var manualPort = String(Wire.defaultPort)
    @State private var showsManualEntry = false

    var body: some View {
        SettingsContainer(title: String(localized: "Connect"), onClose: { dismiss() }) {
            switch link.status {
            case .pairing(let digits, let peerName):
                pairingSection(digits: digits, peerName: peerName)
            case .connected(let name):
                connectedSection(name: name)
            default:
                discoverySection
                manualSection
            }
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    // MARK: - Pairing

    private func pairingSection(digits: String, peerName: String) -> some View {
        SettingsSection(title: String(localized: "Pair with \(peerName)"),
                        footer: String(localized: "Matching codes prove nobody else is between your iPhone and your PC.")) {
            Text(formatted(digits))
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .tracking(4)
                .foregroundStyle(Theme.Palette.label)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .accessibilityLabel(String(localized: "Pairing code \(digits.map(String.init).joined(separator: " "))"))

            Text(String(localized: "Check that your PC shows the same six digits, then confirm on both."))
                .font(.footnote)
                .foregroundStyle(Theme.Palette.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button(String(localized: "Cancel")) { link.rejectPairing() }
                    .buttonStyle(SecondaryButtonStyle())

                Button(String(localized: "They Match")) {
                    link.confirmPairing()
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    // MARK: - Connected

    private func connectedSection(name: String) -> some View {
        SettingsSection(title: String(localized: "Connected"),
                        footer: String(localized: "Your iPhone appears on this PC as iCam Camera and iCam Microphone.")) {
            SettingRow(title: name, subtitle: link.link.displayName) {
                Circle()
                    .fill(Theme.Palette.connected)
                    .frame(width: 8, height: 8)
            }

            if link.diagnostics.latencyUs > 0 {
                SettingRow(title: String(localized: "Latency")) {
                    Text("\(link.diagnostics.latencyUs / 1000) ms")
                        .font(Theme.Typography.readout)
                        .foregroundStyle(Theme.Palette.secondaryLabel)
                }
            }

            Button(String(localized: "Disconnect"), role: .destructive) {
                link.disconnect()
            }
            .buttonStyle(SecondaryButtonStyle(destructive: true))
        }
    }

    // MARK: - Discovery

    private var discoverySection: some View {
        SettingsSection(title: String(localized: "Nearby"),
                        footer: discoveryFooter) {
            if discovery.isBlocked {
                emptyState(symbol: "wifi.exclamationmark",
                           title: String(localized: "Local network access is off"),
                           message: String(localized: "iCam needs it to find computers on your network. Turn it on in Settings › iCam."))
            } else if discovery.peers.isEmpty {
                emptyState(symbol: "desktopcomputer",
                           title: String(localized: "No computers found"),
                           message: String(localized: "Open iCam on your PC. Your devices should appear automatically."))
            } else {
                ForEach(discovery.peers) { peer in
                    Button {
                        link.connect(to: peer)
                        Haptics.select()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                                .font(.title3)
                                .foregroundStyle(Theme.Palette.secondaryLabel)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.name)
                                    .foregroundStyle(Theme.Palette.label)
                                if isTrusted(peer) {
                                    Text(String(localized: "Trusted"))
                                        .font(.footnote)
                                        .foregroundStyle(Theme.Palette.connected)
                                }
                            }
                            Spacer()
                            if case .connecting = link.status {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.Palette.tertiaryLabel)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if case .failed(let message) = link.status {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var discoveryFooter: String? {
        discovery.peers.isEmpty ? nil
            : String(localized: "Both devices must be on the same network.")
    }

    // MARK: - Manual

    private var manualSection: some View {
        SettingsSection(title: String(localized: "By Address"),
                        footer: String(localized: "For networks that block device discovery.")) {
            if showsManualEntry {
                HStack(spacing: 8) {
                    TextField(String(localized: "192.168.1.20"), text: $manualHost)
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.Palette.control))

                    TextField("Port", text: $manualPort)
                        .textFieldStyle(.plain)
                        .keyboardType(.numberPad)
                        .frame(width: 74)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.Palette.control))
                }

                Button(String(localized: "Connect")) {
                    guard let port = UInt16(manualPort), !manualHost.isEmpty else { return }
                    link.connect(host: manualHost, port: port)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(manualHost.isEmpty || UInt16(manualPort) == nil)
            } else {
                Button(String(localized: "Enter an Address")) { showsManualEntry = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    // MARK: - Pieces

    private func emptyState(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(Theme.Palette.tertiaryLabel)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.Palette.label)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Palette.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private func isTrusted(_ peer: DiscoveredPeer) -> Bool {
        guard let fingerprint = peer.fingerprint else { return false }
        return trust.peers.contains { $0.id == fingerprint }
    }

    private func formatted(_ digits: String) -> String {
        guard digits.count == 6 else { return digits }
        let index = digits.index(digits.startIndex, offsetBy: 3)
        return "\(digits[digits.startIndex ..< index]) \(digits[index...])"
    }
}

// MARK: - Button styles

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.Palette.label.opacity(configuration.isPressed ? 0.8 : 1)))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .foregroundStyle(destructive ? Theme.Palette.record : Theme.Palette.label)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.Palette.control.opacity(configuration.isPressed ? 0.6 : 1)))
    }
}
