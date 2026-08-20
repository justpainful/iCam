import SwiftUI

/// A labelled slider with a live readout.
///
/// The readout is the point: a camera control without its current value is a
/// guess. Haptics are deliberately absent — a slider that buzzes on every tick
/// stops meaning anything and costs real battery over a long session.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    /// How the number is rendered — `1/120`, `4800 K`, `+0.7`.
    var format: (Double) -> String
    var isEnabled = true
    var onCommit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(isEnabled ? Theme.Palette.label : Theme.Palette.tertiaryLabel)
                Spacer()
                Text(format(value))
                    .font(Theme.Typography.readoutStrong)
                    .foregroundStyle(isEnabled ? Theme.Palette.secondaryLabel
                                               : Theme.Palette.tertiaryLabel)
            }
            slider
        }
        .padding(.vertical, 4)
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(!isEnabled)
    }

    @ViewBuilder
    private var slider: some View {
        if step > 0 {
            Slider(value: $value, in: range, step: step) { editing in
                if !editing { onCommit?() }
            }
            .tint(Theme.Palette.label)
        } else {
            Slider(value: $value, in: range) { editing in
                if !editing { onCommit?() }
            }
            .tint(Theme.Palette.label)
        }
    }
}

/// A compact segmented choice, styled for a dark camera interface.
struct SegmentedChoice<T: Hashable>: View {
    let title: String?
    let options: [(value: T, label: String)]
    @Binding var selection: T

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.label)
            }
            HStack(spacing: 4) {
                ForEach(options, id: \.value) { option in
                    Button {
                        guard selection != option.value else { return }
                        selection = option.value
                        Haptics.select()
                    } label: {
                        Text(option.label)
                            .font(.footnote.weight(selection == option.value ? .semibold : .regular))
                            .foregroundStyle(selection == option.value
                                             ? Theme.Palette.label : Theme.Palette.secondaryLabel)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background {
                        if selection == option.value {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Theme.Palette.controlActive)
                        }
                    }
                    .accessibilityAddTraits(selection == option.value ? [.isSelected] : [])
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.Palette.control))
        }
    }
}

/// One row in a settings list: a title, an optional explanation, and a value.
struct SettingRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Theme.Palette.label)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.Palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 2)
    }
}

/// A group of related settings under a quiet heading.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.Palette.tertiaryLabel)
                .padding(.horizontal, 4)

            VStack(spacing: 14) { content }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius,
                                             style: .continuous)
                    .fill(Theme.Palette.surface))

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// The chrome shared by both settings screens: black, a title, a close button,
/// and nothing else.
struct SettingsContainer<Content: View>: View {
    let title: String
    var onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) { content }
                    .padding(Theme.Metrics.gutter)
                    .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.Palette.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onClose) {
                        Text(String(localized: "Done")).fontWeight(.semibold)
                    }
                }
            }
            .toolbarBackground(Theme.Palette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.Palette.label)
    }
}
