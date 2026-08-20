import Foundation
import AVFoundation

/// One entry in the lens selector.
///
/// A lens is not always its own `AVCaptureDevice`. On modern iPhones the back
/// camera is a *virtual* device (dual, dual-wide, triple) whose physical lenses
/// are selected by zoom factor. Modelling a lens as "a device plus a zoom
/// factor" is what lets iCam offer smooth optical transitions **and** a real
/// Lens Lock, instead of picking one and pretending the other is impossible.
struct LensOption: Identifiable, Equatable, Sendable {
    var id: String
    /// `0.5`, `1`, `2`, `3` — what the selector shows.
    var label: String
    var position: AVCaptureDevice.Position
    /// The `AVCaptureDevice` to run. May be a virtual device.
    var deviceUniqueID: String
    /// `videoZoomFactor` on that device that selects this physical lens.
    var nativeZoomFactor: Double
    /// Display zoom this lens sits at, relative to the wide lens (`1.0`).
    var displayZoom: Double
    /// Display-zoom range that stays on this physical lens.
    var lockedDisplayZoomRange: ClosedRange<Double>
    var deviceType: AVCaptureDevice.DeviceType
    var supportsMultiCam: Bool
}

/// Enumerates what this iPhone actually has. Nothing here is per-model
/// hardcoded: a device we have never heard of still produces a sensible
/// selector because every value comes from AVFoundation.
final class CameraDeviceManager {

    private(set) var lenses: [LensOption] = []
    private var devicesByID: [String: AVCaptureDevice] = [:]

    /// Ordered richest-first: `DiscoverySession` returns them in this order,
    /// and the first entry is the virtual device that covers the most lenses.
    private static let backTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera,
        .builtInDualWideCamera,
        .builtInDualCamera,
        .builtInWideAngleCamera,
        .builtInUltraWideCamera,
        .builtInTelephotoCamera
    ]

    private static let frontTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTrueDepthCamera,
        .builtInWideAngleCamera
    ]

    func refresh() {
        devicesByID.removeAll()
        var result: [LensOption] = []

        result.append(contentsOf: buildLenses(position: .back, types: Self.backTypes))
        result.append(contentsOf: buildLenses(position: .front, types: Self.frontTypes))

        lenses = result
        Log.camera.notice("Discovered \(result.count, privacy: .public) selectable lenses")
    }

    func device(for lens: LensOption) -> AVCaptureDevice? { devicesByID[lens.deviceUniqueID] }

    func device(uniqueID: String) -> AVCaptureDevice? { devicesByID[uniqueID] }

    func lens(id: String) -> LensOption? { lenses.first { $0.id == id } }

    func lenses(position: AVCaptureDevice.Position) -> [LensOption] {
        lenses.filter { $0.position == position }
    }

    /// The lens iCam starts on: the wide back lens if there is one, otherwise
    /// whatever the first back lens is, otherwise the front camera.
    var defaultLens: LensOption? {
        lenses(position: .back).first { abs($0.displayZoom - 1.0) < 0.01 }
            ?? lenses(position: .back).first
            ?? lenses.first
    }

    // MARK: - Building

    private func buildLenses(position: AVCaptureDevice.Position,
                             types: [AVCaptureDevice.DeviceType]) -> [LensOption] {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                       mediaType: .video,
                                                       position: position)
        // Prefer the richest virtual device: it gives the widest lens range on
        // one session, and switching inside it is smooth rather than a cut.
        guard let primary = session.devices.first else { return [] }
        devicesByID[primary.uniqueID] = primary

        let constituents = primary.constituentDevices
        if constituents.isEmpty {
            // A single physical camera. One entry, zoom is purely digital
            // beyond 1.0.
            let maxZoom = min(Double(primary.activeFormat.videoMaxZoomFactor), 16)
            return [LensOption(id: identifier(position: position, type: primary.deviceType),
                               label: label(for: primary.deviceType, displayZoom: 1.0),
                               position: position,
                               deviceUniqueID: primary.uniqueID,
                               nativeZoomFactor: 1.0,
                               displayZoom: 1.0,
                               lockedDisplayZoomRange: 1.0 ... maxZoom,
                               deviceType: primary.deviceType,
                               supportsMultiCam: primary.isVirtualDevice || supportsMultiCam(primary))]
        }

        // Virtual device. `virtualDeviceSwitchOverVideoZoomFactors` gives the
        // native zoom factor at which each *subsequent* constituent takes over.
        let switchOver = primary.virtualDeviceSwitchOverVideoZoomFactors.map { Double(truncating: $0) }
        var nativeFactors: [Double] = [1.0]
        nativeFactors.append(contentsOf: switchOver)

        // The wide lens is the reference for the numbers the user sees. It is
        // the constituent whose type is `builtInWideAngleCamera`.
        let wideIndex = constituents.firstIndex { $0.deviceType == .builtInWideAngleCamera } ?? 0
        let wideBase = nativeFactors.indices.contains(wideIndex) ? nativeFactors[wideIndex] : 1.0

        let deviceMaxZoom = Double(primary.activeFormat.videoMaxZoomFactor)

        var options: [LensOption] = []
        for (index, constituent) in constituents.enumerated() {
            guard index < nativeFactors.count else { break }
            let native = nativeFactors[index]
            let display = native / wideBase
            let upperNative = index + 1 < nativeFactors.count ? nativeFactors[index + 1] : deviceMaxZoom
            // Stop a hair short of the switch-over point so Lens Lock cannot
            // land exactly on the boundary and flip.
            let upperDisplay = max(display, (upperNative / wideBase) - 0.01)

            options.append(LensOption(id: identifier(position: position, type: constituent.deviceType),
                                      label: label(for: constituent.deviceType, displayZoom: display),
                                      position: position,
                                      deviceUniqueID: primary.uniqueID,
                                      nativeZoomFactor: native,
                                      displayZoom: display,
                                      lockedDisplayZoomRange: display ... upperDisplay,
                                      deviceType: constituent.deviceType,
                                      supportsMultiCam: supportsMultiCam(constituent)))
        }
        return options
    }

    private func supportsMultiCam(_ device: AVCaptureDevice) -> Bool {
        device.formats.contains { $0.isMultiCamSupported }
    }

    private func identifier(position: AVCaptureDevice.Position,
                            type: AVCaptureDevice.DeviceType) -> String {
        let side = position == .front ? "front" : "back"
        let name: String
        switch type {
        case .builtInUltraWideCamera: name = "ultrawide"
        case .builtInWideAngleCamera: name = "wide"
        case .builtInTelephotoCamera: name = "telephoto"
        case .builtInTrueDepthCamera: name = "truedepth"
        default:                      name = type.rawValue.lowercased()
        }
        return "\(side).\(name)"
    }

    /// `0.5`, `1`, `2`, `3` — trimmed the way Apple's own selector trims them.
    private func label(for type: AVCaptureDevice.DeviceType, displayZoom: Double) -> String {
        if displayZoom < 0.995 {
            return String(format: "%.1f", displayZoom)
        }
        let rounded = (displayZoom * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 0.05 {
            return String(Int(rounded.rounded()))
        }
        return String(format: "%.1f", rounded)
    }
}
