import SwiftUI

/// Icons for the things SF Symbols has no honest symbol for.
///
/// House rules, so these sit next to Apple's symbols without looking foreign:
/// drawn on a 24 × 24 grid, 1.6 pt strokes with round caps and joins, no fills
/// except where a filled shape carries the meaning, and every path expressed in
/// terms of the frame so the icon scales with Dynamic Type and tints with
/// `foregroundStyle` like a real symbol does.
enum ICamIcon: String, CaseIterable, Identifiable {
    case zebra
    case falseColor
    case focusPeaking
    case histogram
    case dualRecording
    case pcRecording
    case localRecording
    case safetyRecording
    case virtualCamera
    case lensLock
    case cleanFeed
    case directorMode
    case masterRecording

    var id: String { rawValue }

    var accessibilityLabel: String {
        switch self {
        case .zebra:            return String(localized: "Zebra")
        case .falseColor:       return String(localized: "False Colour")
        case .focusPeaking:     return String(localized: "Focus Peaking")
        case .histogram:        return String(localized: "Histogram")
        case .dualRecording:    return String(localized: "Dual Recording")
        case .pcRecording:      return String(localized: "Record on PC")
        case .localRecording:   return String(localized: "Record on iPhone")
        case .safetyRecording:  return String(localized: "Safety Recording")
        case .virtualCamera:    return String(localized: "Virtual Camera")
        case .lensLock:         return String(localized: "Lens Lock")
        case .cleanFeed:        return String(localized: "Clean Feed")
        case .directorMode:     return String(localized: "Director Mode")
        case .masterRecording:  return String(localized: "Master Recording")
        }
    }
}

/// Renders an `ICamIcon` at a given point size, matching SF Symbol weight.
struct ICamIconView: View {
    let icon: ICamIcon
    var size: CGFloat = 22

    private var lineWidth: CGFloat { max(1.2, size * 1.6 / 24) }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height) / 24
            var transform = CGAffineTransform(scaleX: scale, y: scale)
            let stroke = StrokeStyle(lineWidth: lineWidth / scale,
                                     lineCap: .round, lineJoin: .round)

            for element in Self.path(for: icon) {
                guard let transformed = element.path.copy(using: &transform) else { continue }
                let shape = Path(transformed)
                if element.filled {
                    context.fill(shape, with: .foreground)
                } else {
                    context.stroke(shape, with: .foreground, style: stroke)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(icon.accessibilityLabel)
    }

    private struct Element {
        var path: CGPath
        var filled: Bool
    }

    // MARK: - Geometry, on a 24 × 24 grid

    private static func path(for icon: ICamIcon) -> [Element] {
        switch icon {

        case .zebra:
            // Diagonal bars inside a rounded frame — the pattern itself.
            let frame = CGMutablePath()
            frame.addRoundedRect(in: CGRect(x: 3, y: 5, width: 18, height: 14),
                                 cornerWidth: 3, cornerHeight: 3)
            let bars = CGMutablePath()
            for offset in stride(from: CGFloat(-4), through: 14, by: 5) {
                bars.move(to: CGPoint(x: 6 + offset, y: 18))
                bars.addLine(to: CGPoint(x: 12 + offset, y: 6))
            }
            return [Element(path: frame, filled: false), Element(path: bars, filled: false)]

        case .falseColor:
            // Three stacked bands: the exposure ladder, at a glance.
            var elements: [Element] = []
            for (index, y) in [CGFloat(6), 11, 16].enumerated() {
                let band = CGMutablePath()
                band.addRoundedRect(in: CGRect(x: 4, y: y, width: 16 - CGFloat(index) * 4,
                                               height: 3),
                                    cornerWidth: 1.5, cornerHeight: 1.5)
                elements.append(Element(path: band, filled: index == 0))
            }
            return elements

        case .focusPeaking:
            // A soft subject with a hard, highlighted edge.
            let subject = CGMutablePath()
            subject.addEllipse(in: CGRect(x: 6, y: 6, width: 12, height: 12))
            let edge = CGMutablePath()
            edge.addArc(center: CGPoint(x: 12, y: 12), radius: 8.5,
                        startAngle: -.pi * 0.85, endAngle: -.pi * 0.15, clockwise: false)
            return [Element(path: subject, filled: false), Element(path: edge, filled: false)]

        case .histogram:
            // Bars of varying height on a baseline.
            let bars = CGMutablePath()
            let heights: [CGFloat] = [4, 8, 12, 9, 5, 3]
            for (index, height) in heights.enumerated() {
                let x = 4 + CGFloat(index) * 2.8
                bars.move(to: CGPoint(x: x, y: 18))
                bars.addLine(to: CGPoint(x: x, y: 18 - height))
            }
            let base = CGMutablePath()
            base.move(to: CGPoint(x: 3, y: 19.5))
            base.addLine(to: CGPoint(x: 21, y: 19.5))
            return [Element(path: bars, filled: false), Element(path: base, filled: false)]

        case .dualRecording:
            // Two overlapping capture frames, one solid dot inside.
            let back = CGMutablePath()
            back.addRoundedRect(in: CGRect(x: 3, y: 6, width: 13, height: 12),
                                cornerWidth: 3, cornerHeight: 3)
            let front = CGMutablePath()
            front.addRoundedRect(in: CGRect(x: 8, y: 6, width: 13, height: 12),
                                 cornerWidth: 3, cornerHeight: 3)
            let dot = CGMutablePath()
            dot.addEllipse(in: CGRect(x: 12.5, y: 10.5, width: 3, height: 3))
            return [Element(path: back, filled: false),
                    Element(path: front, filled: false),
                    Element(path: dot, filled: true)]

        case .pcRecording:
            // A display with a record dot.
            let display = CGMutablePath()
            display.addRoundedRect(in: CGRect(x: 3, y: 5, width: 18, height: 12),
                                   cornerWidth: 2.5, cornerHeight: 2.5)
            let stand = CGMutablePath()
            stand.move(to: CGPoint(x: 9, y: 20))
            stand.addLine(to: CGPoint(x: 15, y: 20))
            let dot = CGMutablePath()
            dot.addEllipse(in: CGRect(x: 10.5, y: 9.5, width: 3, height: 3))
            return [Element(path: display, filled: false),
                    Element(path: stand, filled: false),
                    Element(path: dot, filled: true)]

        case .localRecording, .masterRecording:
            // A phone with a record dot. `master` adds a bar to mark the copy
            // that is never derived from anything else.
            let phone = CGMutablePath()
            phone.addRoundedRect(in: CGRect(x: 6, y: 3, width: 12, height: 18),
                                 cornerWidth: 3, cornerHeight: 3)
            let dot = CGMutablePath()
            dot.addEllipse(in: CGRect(x: 10.5, y: 10.5, width: 3, height: 3))
            var elements = [Element(path: phone, filled: false), Element(path: dot, filled: true)]
            if icon == .masterRecording {
                let bar = CGMutablePath()
                bar.move(to: CGPoint(x: 9, y: 17.5))
                bar.addLine(to: CGPoint(x: 15, y: 17.5))
                elements.append(Element(path: bar, filled: false))
            }
            return elements

        case .safetyRecording:
            // A shield around a record dot: the recording that survives.
            let shield = CGMutablePath()
            shield.move(to: CGPoint(x: 12, y: 3))
            shield.addLine(to: CGPoint(x: 20, y: 6.5))
            shield.addLine(to: CGPoint(x: 20, y: 12))
            shield.addCurve(to: CGPoint(x: 12, y: 21),
                            control1: CGPoint(x: 20, y: 17),
                            control2: CGPoint(x: 16, y: 20))
            shield.addCurve(to: CGPoint(x: 4, y: 12),
                            control1: CGPoint(x: 8, y: 20),
                            control2: CGPoint(x: 4, y: 17))
            shield.addLine(to: CGPoint(x: 4, y: 6.5))
            shield.closeSubpath()
            let dot = CGMutablePath()
            dot.addEllipse(in: CGRect(x: 10, y: 10, width: 4, height: 4))
            return [Element(path: shield, filled: false), Element(path: dot, filled: true)]

        case .virtualCamera:
            // A camera body whose lens is drawn as an outline of an outline —
            // a camera that is not quite a camera.
            let body = CGMutablePath()
            body.addRoundedRect(in: CGRect(x: 3, y: 7, width: 18, height: 11),
                                cornerWidth: 3, cornerHeight: 3)
            let lens = CGMutablePath()
            lens.addEllipse(in: CGRect(x: 9, y: 9.5, width: 6, height: 6))
            let dashes = CGMutablePath()
            for angle in stride(from: CGFloat(0), to: .pi * 2, by: .pi / 3) {
                let start = CGPoint(x: 12 + cos(angle) * 4.6, y: 12.5 + sin(angle) * 4.6)
                let end = CGPoint(x: 12 + cos(angle) * 5.6, y: 12.5 + sin(angle) * 5.6)
                dashes.move(to: start)
                dashes.addLine(to: end)
            }
            return [Element(path: body, filled: false),
                    Element(path: lens, filled: false),
                    Element(path: dashes, filled: false)]

        case .lensLock:
            // A lens with a closed shackle over it.
            let lens = CGMutablePath()
            lens.addEllipse(in: CGRect(x: 4, y: 8, width: 12, height: 12))
            let inner = CGMutablePath()
            inner.addEllipse(in: CGRect(x: 7.5, y: 11.5, width: 5, height: 5))
            let shackle = CGMutablePath()
            shackle.addArc(center: CGPoint(x: 17.5, y: 8), radius: 3.5,
                           startAngle: .pi, endAngle: 0, clockwise: false)
            let bodyPath = CGMutablePath()
            bodyPath.addRoundedRect(in: CGRect(x: 13.5, y: 8, width: 8, height: 6),
                                    cornerWidth: 1.5, cornerHeight: 1.5)
            return [Element(path: lens, filled: false),
                    Element(path: inner, filled: false),
                    Element(path: shackle, filled: false),
                    Element(path: bodyPath, filled: false)]

        case .cleanFeed:
            // An empty frame. The absence is the meaning.
            let frame = CGMutablePath()
            frame.addRoundedRect(in: CGRect(x: 3, y: 5, width: 18, height: 14),
                                 cornerWidth: 3, cornerHeight: 3)
            let corners = CGMutablePath()
            corners.move(to: CGPoint(x: 7, y: 9)); corners.addLine(to: CGPoint(x: 7, y: 15))
            corners.move(to: CGPoint(x: 17, y: 9)); corners.addLine(to: CGPoint(x: 17, y: 15))
            return [Element(path: frame, filled: false), Element(path: corners, filled: false)]

        case .directorMode:
            // A three-tile layout: two above, one wide below.
            let tiles = CGMutablePath()
            tiles.addRoundedRect(in: CGRect(x: 3, y: 5, width: 8, height: 6),
                                 cornerWidth: 1.5, cornerHeight: 1.5)
            tiles.addRoundedRect(in: CGRect(x: 13, y: 5, width: 8, height: 6),
                                 cornerWidth: 1.5, cornerHeight: 1.5)
            tiles.addRoundedRect(in: CGRect(x: 3, y: 13, width: 18, height: 6),
                                 cornerWidth: 1.5, cornerHeight: 1.5)
            return [Element(path: tiles, filled: false)]
        }
    }
}
