import SwiftUI
import AppKit

// MARK: - Color tokens

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

    static let driftAccent = adaptive(light: 0x4453F0, dark: 0x8C96FF)
    static let driftTorrent = adaptive(light: 0x0D8A80, dark: 0x4FD1C5)
    static let driftPaused = adaptive(light: 0xB86A00, dark: 0xF5B54A)
    static let driftSuccess = adaptive(light: 0x16803C, dark: 0x4ADE80)
    static let driftDanger = adaptive(light: 0xD92D20, dark: 0xFF6B5E)

    /// Quiet fills for controls and cards, tuned to stay visible in both appearances.
    static let driftFill = adaptive(light: 0xEFF0F3, dark: 0x2A2B31)
    static let driftFillStrong = adaptive(light: 0xE3E5EA, dark: 0x34363D)
    static let driftStroke = adaptive(light: 0xDCDEE4, dark: 0x3A3C44)
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
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .frame(minHeight: 32)
            .background(background(pressed: configuration.isPressed), in: .rect(cornerRadius: 9))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(.rect(cornerRadius: 9))
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary, .plain: .primary
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: Color.driftAccent.opacity(pressed ? 0.8 : 1)
        case .secondary: pressed ? .driftFillStrong : .driftFill
        case .plain: pressed ? .driftFill : .clear
        }
    }
}

extension ButtonStyle where Self == DriftButtonStyle {
    static var driftPrimary: DriftButtonStyle { DriftButtonStyle(kind: .primary) }
    static var driftSecondary: DriftButtonStyle { DriftButtonStyle(kind: .secondary) }
    static var driftPlain: DriftButtonStyle { DriftButtonStyle(kind: .plain) }
}

/// The one icon-button shape in the app: a 30pt circle with a 12pt symbol.
struct IconButton: View {
    let symbol: String
    let label: String
    var tint: Color = .primary
    var filled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(fill, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }

    private var fill: Color {
        if hovering { return .driftFillStrong }
        return filled ? .driftFill : .clear
    }
}

// MARK: - Selection checkbox

/// Round selection checkbox (Photos/Finder style). Plain button, so it responds instantly.
struct SelectionCheckbox: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(isOn ? Color.clear : Color.secondary.opacity(0.55), lineWidth: 1.5)
                    .background(Circle().fill(isOn ? Color.driftAccent : Color.clear))
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 20, height: 20)
            .frame(width: 30, height: 30)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(label, isOn: $isOn)
        }
    }
}

// MARK: - Inputs

/// Rounded field chrome shared by text fields and pickers in the add sheet.
struct FieldChrome: ViewModifier {
    var focused = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color.driftFill, in: .rect(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(focused ? Color.driftAccent : Color.driftStroke, lineWidth: focused ? 2 : 1)
            )
    }
}

extension View {
    func fieldChrome(focused: Bool = false) -> some View { modifier(FieldChrome(focused: focused)) }
}
