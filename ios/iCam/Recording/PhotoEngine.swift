import Foundation
import AVFoundation
import Photos

/// Still capture.
///
/// A photo is never a screenshot of the preview. It goes through
/// `AVCapturePhotoOutput` so it gets the full pipeline — the sensor's real
/// resolution, Deep Fusion or HDR where the device does that, and the correct
/// colour handling.
final class PhotoEngine: NSObject {

    struct Result: Sendable {
        var requestId: UInt32
        var fileURL: URL
        var width: Int
        var height: Int
        var bytes: UInt64
        var savedToLibrary: Bool
    }

    var onResult: ((Result) -> Void)?
    var onError: ((UInt32, ICamError) -> Void)?
    /// Fires the moment the sensor actually captures, so the shutter haptic and
    /// the preview flash land on the real event rather than on the button press.
    var onWillCapture: (() -> Void)?

    private let output: AVCapturePhotoOutput
    private var pending: [Int64: UInt32] = [:]
    private let lock = NSLock()
    private var saveToLibrary = true

    init(output: AVCapturePhotoOutput) {
        self.output = output
        super.init()
    }

    /// - Parameters:
    ///   - requestId: echoed back so a PC-initiated capture can be matched.
    ///   - flashMode: `.auto` only where the device has a flash.
    func capture(requestId: UInt32,
                 state: CameraState,
                 saveToLibrary: Bool,
                 flashMode: AVCaptureDevice.FlashMode,
                 orientationAngle: CGFloat) {
        self.saveToLibrary = saveToLibrary

        var settings: AVCapturePhotoSettings
        // HEIF where the device supports it: same quality, roughly half the
        // bytes. JPEG only as the fallback.
        if output.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        }

        if output.supportedFlashModes.contains(flashMode) {
            settings.flashMode = flashMode
        }
        settings.photoQualityPrioritization = .quality

        // Ask for the sensor's full resolution rather than the video format's.
        let maximum = output.maxPhotoDimensions
        if maximum.width > 0 { settings.maxPhotoDimensions = maximum }

        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(orientationAngle) {
                connection.videoRotationAngle = orientationAngle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = state.mirrored
            }
        }

        lock.lock()
        pending[settings.uniqueID] = requestId
        lock.unlock()

        output.capturePhoto(with: settings, delegate: self)
    }

    /// Raises the output's ceiling to whatever the active format can actually
    /// deliver. Without this the first shot comes out at the video resolution,
    /// and the difference is very visible.
    static func prepare(_ output: AVCapturePhotoOutput, activeFormat: AVCaptureDevice.Format) {
        output.maxPhotoQualityPrioritization = .quality
        if let largest = activeFormat.supportedMaxPhotoDimensions
            .max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            output.maxPhotoDimensions = largest
        }
    }
}

extension PhotoEngine: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput,
                     willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        DispatchQueue.main.async { [weak self] in self?.onWillCapture?() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        lock.lock()
        let requestId = pending.removeValue(forKey: photo.resolvedSettings.uniqueID) ?? 0
        let shouldSave = saveToLibrary
        lock.unlock()

        if let error {
            report(requestId, .internalError(String(describing: error)))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            report(requestId, .internalError("photo produced no data"))
            return
        }

        let ext = photo.isRawPhoto ? "dng" : (data.starts(with: [0xFF, 0xD8]) ? "jpg" : "heic")
        let filename = "IMG-\(RecordingEngine.newSessionId())-\(requestId).\(ext)"
        let url = URL.icamPhotos.appendingPathComponent(filename)

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            report(requestId, .storageFull())
            return
        }

        let dimensions = photo.resolvedSettings.photoDimensions
        let result = Result(requestId: requestId,
                            fileURL: url,
                            width: Int(dimensions.width),
                            height: Int(dimensions.height),
                            bytes: UInt64(data.count),
                            savedToLibrary: shouldSave)

        if shouldSave {
            saveToPhotoLibrary(url: url) { [weak self] in
                DispatchQueue.main.async { self?.onResult?(result) }
            }
        } else {
            DispatchQueue.main.async { [weak self] in self?.onResult?(result) }
        }
    }

    /// Adds the photo to the system library. Uses `.addOnly` authorisation,
    /// which does not grant iCam the ability to read anything the user already
    /// has.
    private func saveToPhotoLibrary(url: URL, completion: @escaping () -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion()
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: url, options: nil)
            }, completionHandler: { _, error in
                if let error {
                    Log.recording.error("Could not add the photo to the library: \(String(describing: error))")
                }
                completion()
            })
        }
    }

    private func report(_ requestId: UInt32, _ error: ICamError) {
        Log.recording.error("Photo capture failed: \(error.detail ?? error.code, privacy: .public)")
        DispatchQueue.main.async { [weak self] in self?.onError?(requestId, error) }
    }
}
