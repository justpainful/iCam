import SwiftUI
import AVFoundation
import UIKit

/// The live preview.
///
/// It is an `AVCaptureVideoPreviewLayer`, not a Metal view drawing frames we
/// received in Swift. The layer is fed by the capture pipeline directly inside
/// the media server: no pixel buffer ever crosses into app memory just to be
/// displayed, which is the single largest power saving available on this
/// screen. Monitoring overlays that genuinely need pixels get their own small,
/// downscaled tap — never this path.
struct CameraPreviewView: UIViewRepresentable {

    let session: AVCaptureSession
    /// Fill crops to the frame; fit shows the whole sensor image.
    var fills: Bool
    var rotationAngle: CGFloat

    /// Point in the preview, already normalised into device coordinates.
    var onFocusTap: (CGPoint, CGPoint) -> Void
    var onZoom: (Double) -> Void
    var onZoomEnded: () -> Void
    var onDoubleTap: () -> Void

    func makeUIView(context: Context) -> PreviewContainer {
        let view = PreviewContainer()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
        view.coordinator = context.coordinator
        context.coordinator.view = view
        view.installGestures(target: context.coordinator)
        return view
    }

    func updateUIView(_ view: PreviewContainer, context: Context) {
        context.coordinator.parent = self
        let gravity: AVLayerVideoGravity = fills ? .resizeAspectFill : .resizeAspect
        if view.previewLayer.videoGravity != gravity {
            view.previewLayer.videoGravity = gravity
        }
        if let connection = view.previewLayer.connection,
           connection.isVideoRotationAngleSupported(rotationAngle),
           connection.videoRotationAngle != rotationAngle {
            connection.videoRotationAngle = rotationAngle
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: - Container

    final class PreviewContainer: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // The layer class is fixed above, so this is a type identity the
            // compiler cannot see rather than an assumption about state.
            guard let layer = layer as? AVCaptureVideoPreviewLayer else {
                return AVCaptureVideoPreviewLayer()
            }
            return layer
        }

        weak var coordinator: Coordinator?

        func installGestures(target: Coordinator) {
            let tap = UITapGestureRecognizer(target: target, action: #selector(Coordinator.handleTap(_:)))
            let doubleTap = UITapGestureRecognizer(target: target,
                                                   action: #selector(Coordinator.handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            tap.require(toFail: doubleTap)

            let pinch = UIPinchGestureRecognizer(target: target,
                                                 action: #selector(Coordinator.handlePinch(_:)))

            addGestureRecognizer(tap)
            addGestureRecognizer(doubleTap)
            addGestureRecognizer(pinch)
        }
    }

    // MARK: - Gestures

    final class Coordinator: NSObject {
        var parent: CameraPreviewView
        weak var view: PreviewContainer?
        private var zoomAtGestureStart: Double = 1

        init(parent: CameraPreviewView) { self.parent = parent }

        /// Current display zoom, pushed in by the view model so a pinch starts
        /// from where the camera actually is.
        var currentZoom: Double = 1

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
            parent.onFocusTap(point, devicePoint)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            parent.onDoubleTap()
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                zoomAtGestureStart = currentZoom
            case .changed:
                // Linear scaling feels wrong at long focal lengths, where the
                // same finger travel should mean a much smaller change.
                let scaled = zoomAtGestureStart * pow(Double(gesture.scale), 1.35)
                parent.onZoom(scaled)
            case .ended, .cancelled, .failed:
                parent.onZoomEnded()
            default:
                break
            }
        }
    }
}
