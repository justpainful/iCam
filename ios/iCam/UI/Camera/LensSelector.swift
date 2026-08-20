import SwiftUI

/// The lens pills: `.5  1  2  3`.
///
/// The contents come from the device, so a phone with one camera shows one
/// pill and a phone with three shows three. Nothing is drawn for a lens this
/// iPhone does not have.
struct LensSelector: View {
    let lenses: [LensOption]
    let activeLensId: String
    let zoom: Double
    let isLocked: Bool
    var onSelect: (LensOption) -> Void
    var onToggleLock: () -> Void

    var body: some View {
        if lenses.count > 1 {
            ICamGlassGroup(spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(lenses) { lens in
                        LensPill(lens: lens,
                                 isActive: lens.id == activeLensId,
                                 zoom: zoom,
                                 action: { onSelect(lens) })
                    }

                    if isLocked {
                        Button(action: onToggleLock) {
                            ICamIconView(icon: .lensLock, size: 15)
                                .foregroundStyle(Theme.Palette.label)
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .icamGlassCapsule(interactive: true,
                                          tint: Theme.Palette.label.opacity(0.16))
                        .accessibilityLabel(String(localized: "Lens Lock is on. Turn it off."))
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(3)
            }
            .icamGlassCapsule()
        }
    }
}

private struct LensPill: View {
    let lens: LensOption
    let isActive: Bool
    let zoom: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: isActive ? 14 : 13, weight: isActive ? .semibold : .regular,
                              design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isActive ? Theme.Palette.label : Theme.Palette.secondaryLabel)
                .frame(minWidth: isActive ? 42 : 34, minHeight: 34)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            if isActive {
                Capsule().fill(Theme.Palette.controlActive)
            }
        }
        .clipShape(Capsule())
        .accessibilityLabel(String(localized: "\(lens.label) times lens"))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    /// The active pill shows the live zoom (`1.7×`); the others show the lens's
    /// own number. That is how a person reads a zoom ring: one live value, and
    /// the stops around it.
    private var label: String {
        guard isActive else { return lens.label }
        if abs(zoom - zoom.rounded()) < 0.05 {
            return "\(Int(zoom.rounded()))×"
        }
        return String(format: "%.1f×", zoom)
    }
}
