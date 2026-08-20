import SwiftUI
import AVFoundation

/// Everything about the *picture*, in one place.
///
/// Progressive disclosure is the organising idea: format and exposure are at
/// the top because most people stop there; ISO, shutter, focus position and
/// tint only appear once the relevant mode is manual, so the screen a beginner
/// sees is short and the screen a professional sees is complete.
struct CameraSettingsScreen: View {
    @ObservedObject var model: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsContainer(title: String(localized: "Camera"), onClose: { dismiss() }) {
            formatSection
            exposureSection
            colourSection
            focusSection
            imageSection
            outputSection
        }
    }

    private var state: CameraState { model.cameraState }

    // MARK: - Format

    private var formatSection: some View {
        SettingsSection(title: String(localized: "Format"),
                        footer: String(localized: "Only combinations this iPhone can actually record are listed.")) {
            if !resolutions.isEmpty {
                SettingRow(title: String(localized: "Resolution")) {
                    Picker("", selection: resolutionBinding) {
                        ForEach(resolutions, id: \.self) { resolution in
                            Text(resolution.displayName).tag(resolution)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            if !frameRates.isEmpty {
                SettingRow(title: String(localized: "Frame Rate")) {
                    Picker("", selection: binding(\.fps, mutate: { $0.fps = $1 })) {
                        ForEach(frameRates, id: \.self) { rate in
                            Text("\(rate) fps").tag(rate)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            SegmentedChoice(title: String(localized: "Codec"),
                            options: [(VideoCodec.h264, "H.264"), (VideoCodec.hevc, "HEVC")],
                            selection: binding(\.codec, mutate: { $0.codec = $1 }))

            if supportsHDR {
                SegmentedChoice(title: String(localized: "HDR"),
                                options: [(HDRMode.off, String(localized: "Off")),
                                          (HDRMode.auto, String(localized: "Auto")),
                                          (HDRMode.on, String(localized: "On"))],
                                selection: binding(\.hdr, mutate: { $0.hdr = $1 }))
            }

            if stabilizationOptions.count > 1 {
                SegmentedChoice(title: String(localized: "Stabilisation"),
                                options: stabilizationOptions.map { ($0, label(for: $0)) },
                                selection: binding(\.stabilization, mutate: { $0.stabilization = $1 }))
            }

            SettingRow(title: String(localized: "Lens Lock"),
                       subtitle: String(localized: "Stops iPhone switching lenses on its own while you shoot.")) {
                Toggle("", isOn: binding(\.lensLocked, mutate: { $0.lensLocked = $1 }))
                    .labelsHidden()
            }
        }
    }

    // MARK: - Exposure

    private var exposureSection: some View {
        SettingsSection(title: String(localized: "Exposure")) {
            SegmentedChoice(title: nil,
                            options: [(ExposureMode.auto, String(localized: "Auto")),
                                      (ExposureMode.manual, String(localized: "Manual"))],
                            selection: binding(\.exposureMode, mutate: { $0.exposureMode = $1 }))

            if state.exposureMode == .auto {
                ValueSlider(title: String(localized: "Exposure Compensation"),
                            value: binding(\.ev, mutate: { $0.ev = $1 }),
                            range: -3 ... 3,
                            step: 0.1,
                            format: { String(format: "%+.1f EV", $0) })

                SettingRow(title: String(localized: "Lock Exposure")) {
                    Toggle("", isOn: binding(\.exposureLocked, mutate: { $0.exposureLocked = $1 }))
                        .labelsHidden()
                }
            } else {
                ValueSlider(title: String(localized: "ISO"),
                            value: binding(\.iso, mutate: { $0.iso = $1 }),
                            range: isoRange,
                            format: { String(format: "%.0f", $0) })

                ValueSlider(title: String(localized: "Shutter"),
                            value: shutterBinding,
                            range: shutterRange,
                            format: { value in
                                let denominator = Int((1_000_000 / max(value, 1)).rounded())
                                return "1/\(denominator)"
                            })
            }
        }
    }

    // MARK: - Colour

    private var colourSection: some View {
        SettingsSection(title: String(localized: "Colour")) {
            SegmentedChoice(title: String(localized: "White Balance"),
                            options: [(WhiteBalanceMode.auto, String(localized: "Auto")),
                                      (WhiteBalanceMode.manual, String(localized: "Manual"))],
                            selection: binding(\.whiteBalanceMode, mutate: { $0.whiteBalanceMode = $1 }))

            if state.whiteBalanceMode == .manual {
                SettingRow(title: String(localized: "Preset")) {
                    Picker("", selection: binding(\.whiteBalancePreset,
                                                  mutate: { $0.whiteBalancePreset = $1 })) {
                        ForEach(WhiteBalancePreset.allCases.filter { $0 != .auto }, id: \.self) {
                            Text(label(for: $0)).tag($0)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                ValueSlider(title: String(localized: "Temperature"),
                            value: binding(\.temperature, mutate: {
                                $0.temperature = $1
                                $0.whiteBalancePreset = .custom
                            }),
                            range: 2_000 ... 10_000,
                            step: 50,
                            format: { String(format: "%.0f K", $0) })

                ValueSlider(title: String(localized: "Tint"),
                            value: binding(\.tint, mutate: {
                                $0.tint = $1
                                $0.whiteBalancePreset = .custom
                            }),
                            range: -150 ... 150,
                            step: 1,
                            format: { String(format: "%+.0f", $0) })
            }
        }
    }

    // MARK: - Focus

    private var focusSection: some View {
        SettingsSection(title: String(localized: "Focus")) {
            SegmentedChoice(title: nil,
                            options: focusOptions,
                            selection: binding(\.focusMode, mutate: { $0.focusMode = $1 }))

            if state.focusMode == .manual, model.capabilities.focus.manual {
                ValueSlider(title: String(localized: "Distance"),
                            value: binding(\.focusPosition, mutate: { $0.focusPosition = $1 }),
                            range: 0 ... 1,
                            format: { value in
                                value < 0.02 ? String(localized: "Near")
                                             : (value > 0.98 ? String(localized: "Infinity")
                                                             : String(format: "%.0f%%", value * 100))
                            })
            }

            SettingRow(title: String(localized: "Prefer Faces"),
                       subtitle: String(localized: "Keeps focus and exposure on people. Turn it off for products or a whiteboard.")) {
                Toggle("", isOn: binding(\.faceDrivenFocus, mutate: { $0.faceDrivenFocus = $1 }))
                    .labelsHidden()
            }
        }
    }

    // MARK: - Image

    private var imageSection: some View {
        SettingsSection(title: String(localized: "Image"),
                        footer: String(localized: "Your computer applies these to the picture it shows and to iCam Camera, so they cost this iPhone nothing. The recording here keeps the untouched picture.")) {
            ValueSlider(title: String(localized: "Brightness"),
                        value: binding(\.brightness, mutate: { $0.brightness = $1 }),
                        range: -1 ... 1, step: 0.05,
                        format: { String(format: "%+.2f", $0) })
            ValueSlider(title: String(localized: "Contrast"),
                        value: binding(\.contrast, mutate: { $0.contrast = $1 }),
                        range: -1 ... 1, step: 0.05,
                        format: { String(format: "%+.2f", $0) })
            ValueSlider(title: String(localized: "Saturation"),
                        value: binding(\.saturation, mutate: { $0.saturation = $1 }),
                        range: -1 ... 1, step: 0.05,
                        format: { String(format: "%+.2f", $0) })
            ValueSlider(title: String(localized: "Warmth"),
                        value: binding(\.warmth, mutate: { $0.warmth = $1 }),
                        range: -1 ... 1, step: 0.05,
                        format: { String(format: "%+.2f", $0) })
            ValueSlider(title: String(localized: "Sharpness"),
                        value: binding(\.sharpness, mutate: { $0.sharpness = $1 }),
                        range: -1 ... 1, step: 0.05,
                        format: { String(format: "%+.2f", $0) })
            ValueSlider(title: String(localized: "Low Light Boost"),
                        value: binding(\.lowLight, mutate: { $0.lowLight = $1 }),
                        range: 0 ... 1, step: 0.05,
                        format: { String(format: "%.0f%%", $0 * 100) })
            ValueSlider(title: String(localized: "Beauty"),
                        value: binding(\.beauty, mutate: { $0.beauty = $1 }),
                        range: 0 ... 1, step: 0.05,
                        format: { String(format: "%.0f%%", $0 * 100) })
        }
    }

    // MARK: - Output

    private var outputSection: some View {
        SettingsSection(title: String(localized: "Output")) {
            if model.capabilities.torch.supported {
                SegmentedChoice(title: String(localized: "Torch"),
                                options: [(TorchMode.off, String(localized: "Off")),
                                          (TorchMode.auto, String(localized: "Auto")),
                                          (TorchMode.on, String(localized: "On"))],
                                selection: binding(\.torch, mutate: { $0.torch = $1 }))

                if state.torch == .on, model.capabilities.torch.levelAdjustable {
                    ValueSlider(title: String(localized: "Torch Level"),
                                value: binding(\.torchLevel, mutate: { $0.torchLevel = $1 }),
                                range: 0.05 ... 1,
                                format: { String(format: "%.0f%%", $0 * 100) })
                }
            }

            SettingRow(title: String(localized: "Mirror"),
                       subtitle: String(localized: "Flips the picture horizontally, the way a mirror would.")) {
                Toggle("", isOn: binding(\.mirrored, mutate: { $0.mirrored = $1 }))
                    .labelsHidden()
            }

            SettingRow(title: String(localized: "Orientation")) {
                Picker("", selection: binding(\.orientation, mutate: { $0.orientation = $1 })) {
                    Text(String(localized: "Auto")).tag(OrientationLock.auto)
                    Text(String(localized: "Portrait")).tag(OrientationLock.portrait)
                    Text(String(localized: "Landscape Left")).tag(OrientationLock.landscapeLeft)
                    Text(String(localized: "Landscape Right")).tag(OrientationLock.landscapeRight)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    // MARK: - Bindings

    /// Every control writes through a mutation, so the phone and the PC go
    /// through the same path and the same clamping.
    private func binding<V>(_ keyPath: KeyPath<CameraState, V>,
                            mutate: @escaping (inout CameraMutation, V) -> Void) -> Binding<V> {
        Binding(
            get: { model.cameraState[keyPath: keyPath] },
            set: { newValue in
                var mutation = CameraMutation()
                mutate(&mutation, newValue)
                model.apply(mutation)
            })
    }

    private var resolutionBinding: Binding<Resolution> {
        Binding(
            get: { Resolution(width: state.width, height: state.height) },
            set: { resolution in
                var mutation = CameraMutation()
                mutation.width = resolution.width
                mutation.height = resolution.height
                model.apply(mutation)
            })
    }

    /// Shutter is stored as a duration but read as a fraction, so the slider
    /// works in microseconds and the label prints `1/120`.
    private var shutterBinding: Binding<Double> {
        Binding(
            get: { Double(state.exposureDurationUs) },
            set: { value in
                var mutation = CameraMutation()
                mutation.exposureDurationUs = Int(value)
                model.apply(mutation)
            })
    }

    // MARK: - Capability lookups

    private var resolutions: [Resolution] {
        model.capabilities.resolutions(forLens: state.lensId)
    }

    private var frameRates: [Int] {
        model.capabilities.frameRates(forLens: state.lensId,
                                      width: state.width, height: state.height)
    }

    private var supportsHDR: Bool {
        model.capabilities.formats(forLens: state.lensId)
            .contains { $0.width == state.width && $0.height == state.height && $0.hdr }
    }

    private var stabilizationOptions: [Stabilization] {
        let all = model.capabilities.formats(forLens: state.lensId)
            .flatMap(\.stabilization)
        var seen: [Stabilization] = []
        for mode in [Stabilization.off, .standard, .cinematic, .auto] where all.contains(mode) {
            seen.append(mode)
        }
        return seen
    }

    private var isoRange: ClosedRange<Double> {
        guard let format = model.capabilities.formats(forLens: state.lensId)
            .first(where: { $0.width == state.width && $0.height == state.height }),
              format.isoRange.count == 2, format.isoRange[1] > format.isoRange[0] else {
            return 50 ... 3_200
        }
        return format.isoRange[0] ... format.isoRange[1]
    }

    private var shutterRange: ClosedRange<Double> {
        guard let format = model.capabilities.formats(forLens: state.lensId)
            .first(where: { $0.width == state.width && $0.height == state.height }),
              format.exposureDurationUsRange.count == 2,
              format.exposureDurationUsRange[1] > format.exposureDurationUsRange[0] else {
            return 250 ... 100_000
        }
        // Cap the long end at a quarter second: anything slower is unusable for
        // handheld video and only makes the slider harder to aim.
        return Double(format.exposureDurationUsRange[0])
            ... min(Double(format.exposureDurationUsRange[1]), 250_000)
    }

    private var focusOptions: [(FocusMode, String)] {
        var options: [(FocusMode, String)] = [
            (.continuous, String(localized: "Continuous")),
            (.single, String(localized: "Single"))
        ]
        if model.capabilities.focus.manual {
            options.append((.manual, String(localized: "Manual")))
        }
        return options
    }

    private func label(for mode: Stabilization) -> String {
        switch mode {
        case .off:               return String(localized: "Off")
        case .standard:          return String(localized: "Standard")
        case .cinematic:         return String(localized: "Cinematic")
        case .cinematicExtended: return String(localized: "Cinematic+")
        case .auto:              return String(localized: "Auto")
        }
    }

    private func label(for preset: WhiteBalancePreset) -> String {
        switch preset {
        case .auto:        return String(localized: "Auto")
        case .daylight:    return String(localized: "Daylight")
        case .cloudy:      return String(localized: "Cloudy")
        case .shade:       return String(localized: "Shade")
        case .tungsten:    return String(localized: "Tungsten")
        case .fluorescent: return String(localized: "Fluorescent")
        case .warm:        return String(localized: "Warm")
        case .custom:      return String(localized: "Custom")
        }
    }
}
