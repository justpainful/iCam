import UIKit

/// Haptics, used sparingly.
///
/// One rule: a haptic marks a *state change the user caused and cares about* —
/// the shutter firing, recording starting, a lens switching, a lock engaging.
/// Never a slider tick. A slider that buzzes continuously stops meaning
/// anything and costs real battery over a long session.
@MainActor
enum Haptics {

    private static let selection = UISelectionFeedbackGenerator()
    private static let impactLight = UIImpactFeedbackGenerator(style: .light)
    private static let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()

    static var isEnabled = true

    /// Call just before a haptic is likely, so the Taptic Engine is already
    /// awake and the feedback lands on the event rather than after it.
    static func prepare() {
        guard isEnabled else { return }
        selection.prepare()
        impactMedium.prepare()
    }

    /// Lens switch, mode change, segment selection.
    static func select() {
        guard isEnabled else { return }
        selection.selectionChanged()
    }

    /// The shutter fired.
    static func shutter() {
        guard isEnabled else { return }
        impactMedium.impactOccurred(intensity: 0.9)
    }

    /// Recording started or stopped.
    static func record(starting: Bool) {
        guard isEnabled else { return }
        impactMedium.impactOccurred(intensity: starting ? 1.0 : 0.7)
    }

    /// Focus or exposure locked.
    static func lock() {
        guard isEnabled else { return }
        impactLight.impactOccurred(intensity: 0.7)
    }

    /// Connected to a computer, or disconnected from one.
    static func connection(success: Bool) {
        guard isEnabled else { return }
        notification.notificationOccurred(success ? .success : .warning)
    }

    /// Something the user needs to know went wrong.
    static func warning() {
        guard isEnabled else { return }
        notification.notificationOccurred(.error)
    }
}
