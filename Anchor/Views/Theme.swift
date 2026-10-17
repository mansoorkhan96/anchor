import SwiftUI
import AppKit

// MARK: - Brand

/// The app's primary color, like a CSS `--primary` variable. Every accent shade below is mixed from it,
/// so changing the brand color is this one line.
enum Brand {
    static let primary: UInt32 = 0xEB6840

    /// Light and dark window backgrounds the tints are mixed into.
    fileprivate static let lightGround: UInt32 = 0xFFFFFF
    fileprivate static let darkGround: UInt32 = 0x1B1B1D

    /// `from` moved `amount` (0...1) of the way toward `to`, like CSS `color-mix()`.
    fileprivate static func mix(_ from: UInt32, _ to: UInt32, _ amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let a = Double((from >> shift) & 0xFF), b = Double((to >> shift) & 0xFF)
            return UInt32((a + (b - a) * amount).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
}

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

    // Accent: all derived from Brand.primary.
    static let anchorAccent = adaptive(light: Brand.primary, dark: Brand.mix(Brand.primary, 0xFFFFFF, 0.15))
    /// Filled buttons and badges: the primary itself.
    static let anchorAccentStrong = anchorAccent
    /// Accent-colored text and links: a touch deeper than the primary so it stays readable on white.
    static let anchorAccentInk = adaptive(light: Brand.mix(Brand.primary, 0x000000, 0.08),
                                         dark: Brand.mix(Brand.primary, 0xFFFFFF, 0.35))
    static let anchorAccentWash = adaptive(light: Brand.mix(Brand.lightGround, Brand.primary, 0.08),
                                          dark: Brand.mix(Brand.darkGround, Brand.primary, 0.16))
    static let anchorAccentTint = adaptive(light: Brand.mix(Brand.lightGround, Brand.primary, 0.18),
                                          dark: Brand.mix(Brand.darkGround, Brand.primary, 0.26))
    static let anchorAccentRing = adaptive(light: Brand.mix(Brand.lightGround, Brand.primary, 0.6),
                                          dark: Brand.mix(Brand.darkGround, Brand.primary, 0.6))
    static let anchorAccentEdge = adaptive(light: Brand.mix(Brand.lightGround, Brand.primary, 0.32),
                                          dark: Brand.mix(Brand.darkGround, Brand.primary, 0.4))

    // Neutrals
    static let anchorWindow = adaptive(light: 0xFFFFFF, dark: 0x1B1B1D)
    static let anchorCard = adaptive(light: 0xF7F7F7, dark: 0x252527)
    static let anchorCardQuiet = adaptive(light: 0xFBFBFB, dark: 0x202022)
    static let anchorField = adaptive(light: 0xF2F2F4, dark: 0x2E2E31)
    static let anchorLine = adaptive(light: 0xECECEE, dark: 0x38383B)
    static let anchorText = adaptive(light: 0x1D1D1F, dark: 0xF2F2F4)
    static let anchorMuted = adaptive(light: 0x737378, dark: 0x9C9CA1)
    static let anchorMuted2 = adaptive(light: 0x5E5E63, dark: 0xB4B4B9)
    static let anchorTrack = adaptive(light: 0xE8E8EB, dark: 0x3A3A3E)

    // States
    static let anchorTorrent = adaptive(light: 0x61B790, dark: 0x6FCB9F)
    static let anchorPaused = adaptive(light: 0xE8B248, dark: 0xF0C060)
    static let anchorPausedInk = adaptive(light: 0xA86F0B, dark: 0xF0C060)
    /// Paused downloads: a cool slate, so "inactive" never reads like the orange accent.
    static let anchorIdle = adaptive(light: 0x8A9099, dark: 0x9BA2AC)
    static let anchorIdleInk = adaptive(light: 0x5A616B, dark: 0xC2C7CF)
    static let anchorSuccess = adaptive(light: 0x2F7D3A, dark: 0x6FD38A)
    static let anchorDone = adaptive(light: 0x4FAE5C, dark: 0x5FC46E)
    static let anchorQueued = adaptive(light: 0xA1A1A6, dark: 0x7C7C82)
    static let anchorSuccessWash = adaptive(light: 0xE4F3E5, dark: 0x1F3524)
    static let anchorDanger = adaptive(light: 0xD93A4A, dark: 0xFF6B78)
    static let anchorDangerWash = adaptive(light: 0xFDECEE, dark: 0x3D2226)
}

// MARK: - Buttons

/// Text buttons used across sheets, banners and settings.
struct AnchorButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: kind == .primary ? .semibold : .medium))
            .foregroundStyle(kind == .primary ? Color.white : Color.anchorText)
            .padding(.horizontal, kind == .plain ? 12 : 16)
            .frame(minHeight: 34)
            .background(background(pressed: configuration.isPressed), in: .rect(cornerRadius: 10))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(.rect(cornerRadius: 10))
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: Color.anchorAccent.opacity(pressed ? 0.85 : 1)
        case .secondary: pressed ? .anchorLine : .anchorField
        case .plain: pressed ? .anchorField : .clear
        }
    }
}

extension ButtonStyle where Self == AnchorButtonStyle {
    static var anchorPrimary: AnchorButtonStyle { AnchorButtonStyle(kind: .primary) }
    static var anchorSecondary: AnchorButtonStyle { AnchorButtonStyle(kind: .secondary) }
    static var anchorPlain: AnchorButtonStyle { AnchorButtonStyle(kind: .plain) }
}

/// The one round icon button in the app.
struct IconButton: View {
    let symbol: String
    let label: String
    var tint: Color = .anchorText
    var fill: Color = .anchorText.opacity(0.07)
    var size: CGFloat = 32
    /// Draws a hairline edge so light buttons don't fade into a white background.
    var outlined = false
    /// Glyph size as a fraction of the button.
    var glyphScale: CGFloat = 0.37
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * glyphScale, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(fill, in: .circle)
                .overlay(Circle().strokeBorder(outlined ? Color.anchorLine : .clear))
                .overlay(Circle().fill(Color.anchorText.opacity(hovering ? 0.06 : 0)))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .allowsWindowActivationEvents(true)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// "Show in Finder" button using the real, colorful Finder icon.
struct RevealButton: View {
    var size: CGFloat = 32
    var outlined = false
    let action: () -> Void
    @State private var hovering = false

    private static let finderIcon: NSImage = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")

    var body: some View {
        Button(action: action) {
            Image(nsImage: Self.finderIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: size * 0.66, height: size * 0.66)
                .frame(width: size, height: size)
                .background(Color.anchorText.opacity(hovering ? 0.1 : 0.06), in: .circle)
                .overlay(Circle().strokeBorder(outlined ? Color.anchorLine : .clear))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .allowsWindowActivationEvents(true)
        .onHover { hovering = $0 }
        .help("Show in Finder")
        .accessibilityLabel("Show in Finder")
    }
}

// MARK: - Selection checkbox

/// Square selection checkbox, matching the torrent file checkboxes. Works on the first click even when the
/// window isn't focused.
struct SelectionCheckbox: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(isOn ? Color.anchorAccent : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isOn ? Color.clear : Color.anchorText.opacity(0.22), lineWidth: 1.5))
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8.5, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 16, height: 16)
                .frame(width: 24, height: 28)
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
struct AnchorSwitch: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Capsule()
                .fill(isOn ? Color.anchorAccent : Color.anchorTrack)
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
            .background(focused ? Color.anchorWindow : Color.anchorField, in: .rect(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(focused ? Color.anchorAccent : Color.clear, lineWidth: 1.5)
            )
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(focused ? Color.anchorAccentTint : Color.clear)
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
    var ink: Color = .anchorMuted2
    var wash: Color = .anchorField

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

/// Segmented control: rounded gray track, equal-width segments, and a white selected pill that slides.
struct AnchorSegmented<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var minWidth: CGFloat = 40
    var symbol: ((Value) -> String)? = nil
    var height: CGFloat = 34
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = option }
                } label: {
                    HStack(spacing: 5) {
                        if let symbol {
                            Image(systemName: symbol(option))
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        Text(title(option))
                            .font(.system(size: 12.5, weight: on ? .semibold : .medium).monospacedDigit())
                            .lineLimit(1)
                    }
                    .foregroundStyle(on ? Color.anchorAccentInk : Color.anchorMuted)
                    .padding(.horizontal, 10)
                    .frame(minWidth: minWidth, maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.anchorWindow)
                                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(height: height)
        .background(Color.anchorField, in: .rect(cornerRadius: 10))
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Status pill

/// Colored status badge for a download (nil while actively downloading, where the speed is shown instead).
/// The up-and-down chevron at the end of a pop-up menu field. Decorative, so VoiceOver skips it; size and color come
/// from the caller's modifiers.
struct MenuChevron: View {
    var body: some View {
        Image(systemName: "chevron.up.chevron.down").accessibilityHidden(true)
    }
}

struct StatusPill: View {
    let state: DownloadState
    var compact = false

    var body: some View {
        if let style {
            HStack(spacing: compact ? 3 : 4) {
                Image(systemName: style.symbol)
                    .font(.system(size: compact ? 8 : 9, weight: .bold))
                Text(style.text)
                    .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(style.ink)
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, compact ? 2 : 4)
            .background(style.wash, in: .capsule)
            .accessibilityElement(children: .combine)
        }
    }

    private var style: (text: String, symbol: String, ink: Color, wash: Color)? {
        switch state {
        case .downloading: nil
        case .connecting: ("Connecting", "arrow.triangle.2.circlepath", .anchorAccentInk, .anchorAccentWash)
        case .queued: ("Queued", "clock", .anchorMuted2, .anchorField)
        case .paused: ("Paused", "pause.fill", .anchorIdleInk, Color.anchorIdle.opacity(0.16))
        case .failed: ("Failed", "exclamationmark.triangle.fill", .anchorDanger, .anchorDangerWash)
        case .completed: ("Done", "checkmark", .anchorSuccess, .anchorSuccessWash)
        }
    }
}
