import Foundation
import SwiftUI
import Combine
import UIKit

/// The composition root.
///
/// Every long-lived object is built here, once, and handed down. Nothing in the
/// app reaches for a singleton, which is what makes the pieces testable in
/// isolation and keeps the ownership graph obvious.
@MainActor
final class AppEnvironment: ObservableObject {

    let settings = AppSettings()
    let thermal = ThermalManager()
    let battery = BatteryManager()
    let storage = StorageMonitor()
    let trustStore = TrustStore()
    let discovery = Discovery()

    let link: PeerLink
    let camera: CameraViewModel
    /// Answers the PC when it dials through the cable.
    private let usbListener = UsbTunnelListener()

    /// Recordings that were interrupted, found at launch. Offered to the user
    /// once; never deleted on their behalf.
    @Published var interruptedSessions: [RecoveryManager.InterruptedSession] = []

    private var cancellables = Set<AnyCancellable>()

    init() {
        let identity: DeviceIdentity
        do {
            identity = try IdentityStore.loadOrCreate()
        } catch {
            // The keychain is unavailable. iCam still works as a camera; only
            // PC pairing is affected, and a fresh in-memory identity means the
            // user is asked to pair again rather than silently trusting nothing.
            Log.security.error("Falling back to an ephemeral identity: \(String(describing: error))")
            identity = DeviceIdentity(privateKey: .init())
        }

        let info = DeviceInfo(name: UIDevice.current.name,
                              model: AppEnvironment.hardwareModel,
                              os: UIDevice.current.systemVersion,
                              app: AppSettingsScreen.versionString,
                              id: identity.fingerprint)

        link = PeerLink(identity: identity, deviceInfo: info, trustStore: trustStore)
        camera = CameraViewModel(settings: settings, thermal: thermal, storage: storage)
        camera.attach(link: link)

        thermal.mode = settings.thermalMode
        thermal.efficiencyMode = settings.efficiencyMode

        interruptedSessions = RecoveryManager.findInterruptedSessions()
        if !interruptedSessions.isEmpty {
            Log.recording.notice("Found \(self.interruptedSessions.count, privacy: .public) interrupted recordings")
        }

        observeAutoConnect()

        // Direct USB: always listening. A cable arriving IS the user intent,
        // so there is no switch to find first — plug in, and the PC's tunnel
        // lands here and becomes an ordinary session.
        usbListener.onConnection = { [weak self] connection in
            self?.link.adoptIncoming(connection)
        }
        usbListener.start()
    }

    // MARK: - Scene

    func handle(scenePhase: ScenePhase) {
        switch scenePhase {
        case .background:
            camera.applicationDidEnterBackground()
            // Discovery is stopped in the background: an idle Bonjour browser
            // still keeps the radio awake, and nobody is looking at the list.
            discovery.stop()
        case .active:
            storage.refresh()
            if settings.autoConnectToTrusted { attemptAutoConnect() }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Auto connect

    /// Rejoins a trusted computer as soon as it appears, without asking.
    ///
    /// Only ever connects to a peer whose advertised identity fingerprint is
    /// already in the trust store — a computer that merely took over the name
    /// or address of a paired one is not enough.
    private func observeAutoConnect() {
        discovery.$peers
            .receive(on: RunLoop.main)
            .sink { [weak self] peers in
                guard let self, self.settings.autoConnectToTrusted else { return }
                guard case .disconnected = self.link.status else { return }
                guard let match = peers.first(where: { peer in
                    guard let fingerprint = peer.fingerprint else { return false }
                    return self.trustStore.peers.contains { $0.id == fingerprint && $0.autoConnect }
                }) else { return }
                self.link.connect(to: match)
            }
            .store(in: &cancellables)
    }

    private func attemptAutoConnect() {
        guard case .disconnected = link.status, !trustStore.peers.isEmpty else { return }
        discovery.start()
    }

    func dismissRecovery(_ session: RecoveryManager.InterruptedSession) {
        try? RecoveryManager.markRecovered(session)
        interruptedSessions.removeAll { $0.id == session.id }
    }

    // MARK: - Device

    /// `iPhone16,1`. Used for the device info the PC displays; never used to
    /// decide what the camera can do — that always comes from AVFoundation.
    static var hardwareModel: String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(bitPattern: value))))
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }
}
