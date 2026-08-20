import Foundation
import os

/// Structured logging.
///
/// Rules, enforced by review:
/// - never log media bytes, photo contents, or audio samples;
/// - never log key material, pairing digits, or handshake secrets;
/// - device names and identity fingerprints are `.private` by default.
enum Log {
    private static let subsystem = "com.icam.app"

    static let app       = Logger(subsystem: subsystem, category: "app")
    static let camera    = Logger(subsystem: subsystem, category: "camera")
    static let recording = Logger(subsystem: subsystem, category: "recording")
    static let stream    = Logger(subsystem: subsystem, category: "stream")
    static let net       = Logger(subsystem: subsystem, category: "net")
    static let security  = Logger(subsystem: subsystem, category: "security")
    static let thermal   = Logger(subsystem: subsystem, category: "thermal")
    static let storage   = Logger(subsystem: subsystem, category: "storage")
}

/// A user-facing error. Every error surfaced in the interface is one of these,
/// so the interface can never show `AVError -11800` to an ordinary user.
struct ICamError: LocalizedError, Equatable {
    /// Stable machine identifier, matches `docs/PROTOCOL.md` section 9.
    let code: String
    /// Already-localised, human sentence. Shown as-is.
    let title: String
    /// Already-localised explanation. Shown under the title.
    let message: String
    /// Technical text. Only ever shown inside Developer Diagnostics.
    let detail: String?

    var errorDescription: String? { title }
    var failureReason: String? { message }

    init(code: String, title: String, message: String, detail: String? = nil) {
        self.code = code
        self.title = title
        self.message = message
        self.detail = detail
    }

    static func cameraBusy(detail: String? = nil) -> ICamError {
        ICamError(code: "camera.busy",
                  title: String(localized: "Camera unavailable"),
                  message: String(localized: "Another app or a system service is using the camera. Close it and try again."),
                  detail: detail)
    }

    static func cameraUnavailable(detail: String? = nil) -> ICamError {
        ICamError(code: "camera.unavailable",
                  title: String(localized: "No camera found"),
                  message: String(localized: "iCam could not find a usable camera on this device."),
                  detail: detail)
    }

    static func permissionDenied(_ what: String) -> ICamError {
        ICamError(code: "permission.denied",
                  title: String(localized: "\(what) access is off"),
                  message: String(localized: "Turn it on in Settings to use this part of iCam."),
                  detail: nil)
    }

    static func storageFull() -> ICamError {
        ICamError(code: "storage.full",
                  title: String(localized: "Not enough storage"),
                  message: String(localized: "Free up space on your iPhone to keep recording."),
                  detail: nil)
    }

    static func recordFailed(detail: String? = nil) -> ICamError {
        ICamError(code: "record.failed",
                  title: String(localized: "Recording stopped"),
                  message: String(localized: "iCam saved everything it had written up to this point."),
                  detail: detail)
    }

    static func internalError(_ detail: String) -> ICamError {
        ICamError(code: "internal",
                  title: String(localized: "Something went wrong"),
                  message: String(localized: "iCam ran into an unexpected problem."),
                  detail: detail)
    }
}
