import SwiftUI
import AppKit

// MARK: - Color tokens (Vitals palette: white, soft gray cards, system blue)

extension Color {
    /// A color with separate light and dark appearance values.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    // Accent
    static let driftAccent = adaptive(light: 0x418FF8, dark: 0x5AA0FF)
    /// Filled buttons: a deeper blue so white text stays readable.
    static let driftAccentStrong = adaptive(light: 0x2B73E6, dark: 0x3D85F5)
    /// Blue text and links.
    static let driftAccentInk = adaptive(light: 0x1F63C6, dark: 0x8DBBFF)
    static let driftAccentWash = adaptive(light: 0xEEF5FE, dark: 0x1D2B40)
    static let driftAccentTint = adaptive(light: 0xDCEAFD, dark: 0x24395A)
    static let driftAccentRing = adaptive(light: 0x7FB3FB, dark: 0x4A79C2)

    // Neutrals
    static let driftWindow = adaptive(light: 0xFFFFFF, dark: 0x1B1B1D)
    static let driftCard = adaptive(light: 0xF7F7F7, dark: 0x252527)
    static let driftCardQuiet = adaptive(light: 0xFBFBFB, dark: 0x202022)
    static let driftField = adaptive(light: 0xF2F2F4, dark: 0x2E2E31)
    static let driftLine = adaptive(light: 0xECECEE, dark: 0x38383B)
    static let driftText = adaptive(light: 0x1D1D1F, dark: 0xF2F2F4)
    static let driftMuted = adaptive(light: 0x737378, dark: 0x9C9CA1)
    static let driftMuted2 = adaptive(light: 0x5E5E63, dark: 0xB4B4B9)
    static let driftTrack = adaptive(light: 0xE8E8EB, dark: 0x3A3A3E)

    // States
    static let driftTorrent = adaptive(light: 0x61B790, dark: 0x6FCB9F)
    static let driftPaused = adaptive(light: 0xE8B248, dark: 0xF0C060)
    static let driftPausedInk = adaptive(light: 0xA86F0B, dark: 0xF0C060)
    static let driftSuccess = adaptive(light: 0x2F7D3A, dark: 0x6FD38A)
    static let driftSuccessWash = adaptive(light: 0xE4F3E5, dark: 0x1F3524)
    static let driftDanger = adaptive(light: 0xD93A4A, dark: 0xFF6B78)
    static let driftDangerWash = adaptive(light: 0xFDECEE, dark: 0x3D2226)
}

// MARK: - Buttons

/// Text buttons used across sheets, banners and settings.
struct DriftButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: kind == .primary ? .semibold : .medium))
            .foregroundStyle(kind == .primary ? Color.white : Color.driftText)
            .padding(.horizontal, kind == .plain ? 12 : 16)
            .frame(minHeight: 34)
            .background(background(pressed: configuration.isPressed), in: .rect(cornerRadius: 10))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(.rect(cornerRadius: 10))
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: Color.driftAccentStrong.opacity(pressed ? 0.85 : 1)
        case .secondary: pressed ? .driftLine : .driftField
        case .plain: pressed ? .driftField : .clear
        }
    }
}

extension ButtonStyle where Self == DriftButtonStyle {
    static var driftPrimary: DriftButtonStyle { DriftButtonStyle(kind: .primary) }
    static var driftSecondary: DriftButtonStyle { DriftButtonStyle(kind: .secondary) }
    static var driftPlain: DriftButtonStyle { DriftButtonStyle(kind: .plain) }
}

/// The one round icon button in the app.
struct IconButton: View {
    let symbol: String
    let label: String
    var tint: Color = .driftText
    var fill: Color = .driftText.opacity(0.07)
    var size: CGFloat = 32
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.37, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(fill, in: .circle)
                .overlay(Circle().fill(Color.driftText.opacity(hovering ? 0.06 : 0)))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .allowsWindowActivationEvents(true)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Selection checkbox

/// Round selection checkbox. Works on the first click even when the window isn't focused.
struct SelectionCheckbox: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(isOn ? Color.clear : Color.driftText.opacity(0.25), lineWidth: 1.5)
                    .background(Circle().fill(isOn ? Color.driftAccent : Color.clear))
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 22, height: 22)
            .frame(width: 32, height: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .allowsWindowActivationEvents(true)
        .transaction { $0.animation = nil }
        .accessibilityRepresentation {
            Toggle(label, isOn: $isOn)
        }
    }
}

// MARK: - Switch

/// Compact blue switch matching the design.
struct DriftSwitch: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Capsule()
                .fill(isOn ? Color.driftAccent : Color.driftTrack)
                .frame(width: 38, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                        .padding(2)
                }
                .animation(.snappy(duration: 0.18), value: isOn)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .allowsWindowActivationEvents(true)
        .accessibilityRepresentation {
            Toggle(label, isOn: $isOn)
        }
    }
}

// MARK: - Fields and chips

/// Filled soft-gray field chrome with a blue focus ring.
struct FieldChrome: ViewModifier {
    var focused = false
    var height: CGFloat = 40

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(focused ? Color.driftWindow : Color.driftField, in: .rect(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(focused ? Color.driftAccent : Color.clear, lineWidth: 1.5)
            )
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(focused ? Color.driftAccentTint : Color.clear)
                    .padding(-3)
            )
    }
}

extension View {
    func fieldChrome(focused: Bool = false, height: CGFloat = 40) -> some View {
        modifier(FieldChrome(focused: focused, height: height))
    }
}

/// Small soft-filled tag, like Vitals' "Normal · 43%".
struct Chip: View {
    let text: String
    var ink: Color = .driftMuted2
    var wash: Color = .driftField

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(wash, in: .capsule)
    }
}

/// Segmented control styled like the design: gray track, white selected pill with blue text.
struct DriftSegmented<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var minWidth: CGFloat = 40

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(on ? Color.driftAccentInk : Color.driftMuted2)
                        .frame(minWidth: minWidth, minHeight: 28)
                        .padding(.horizontal, 4)
                        .background(on ? Color.driftWindow : .clear, in: .rect(cornerRadius: 7))
                        .shadow(color: .black.opacity(on ? 0.1 : 0), radius: 1, y: 1)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.driftLine, in: .rect(cornerRadius: 9))
    }
}
