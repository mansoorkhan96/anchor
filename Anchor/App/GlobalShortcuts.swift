import AppKit
import Carbon.HIToolbox
import Observation

/// A key and its modifiers, as recorded in Settings > Shortcuts. `key` is the key's label at recording time
/// ("V", "Space", "F5"), so it shows the way it is printed on this keyboard.
struct KeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier flags (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var modifiers: UInt32
    var key: String

    /// "⌃⌥⌘V", in the order macOS menus use.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key
    }

    /// Function keys work on their own; anything else needs ⌘, ⌥ or ⌃, or it would fire while typing.
    var isUsable: Bool {
        let strong = UInt32(cmdKey | optionKey | controlKey)
        return modifiers & strong != 0 || Self.functionKeys[keyCode] != nil
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// The combination a key press makes; nil for a lone modifier key.
    init?(event: NSEvent) {
        let code = UInt32(event.keyCode)
        let flags = event.modifierFlags
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        guard let name = Self.name(keyCode: code, characters: event.charactersIgnoringModifiers) else { return nil }
        self.init(keyCode: code, modifiers: carbon, key: name)
    }

    static func name(keyCode: UInt32, characters: String?) -> String? {
        if let special = specialKeys[keyCode] ?? functionKeys[keyCode] { return special }
        guard let characters, let first = characters.first, !first.isWhitespace, !first.isNewline,
              first.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return String(first).uppercased()
    }

    private static let specialKeys: [UInt32: String] = [
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_Escape): "⎋", UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓", UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
    ]

    private static let functionKeys: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12", UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16", UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18", UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
    ]
}

/// What a system-wide shortcut can do. The raw values are the keys they are saved under.
enum GlobalShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case newDownload, addFromClipboard, showAnchor, menuBarPanel, pauseAll, resumeAll, toggleSpeedLimit, startQueue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newDownload: "New download"
        case .addFromClipboard: "Download link on the clipboard"
        case .showAnchor: "Show Anchor"
        case .menuBarPanel: "Open the menu bar panel"
        case .pauseAll: "Pause all downloads"
        case .resumeAll: "Resume all downloads"
        case .toggleSpeedLimit: "Turn the speed limit on or off"
        case .startQueue: "Start queued downloads now"
        }
    }

    var detail: String? {
        switch self {
        case .addFromClipboard: "Opens the New Download window with the link you copied"
        case .startQueue: "Even outside the download schedule"
        default: nil
        }
    }

    @MainActor
    func perform() {
        let store = DownloadStore.shared
        switch self {
        case .newDownload:
            AppRouter.shared.present(AddRequest())
        case .addFromClipboard:
            let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            AppRouter.shared.present(AddRequest(url: text))
        case .showAnchor:
            AppRouter.shared.activate()
        case .menuBarPanel:
            AppRouter.shared.toggleMenuBarPanel()
        case .pauseAll:
            store.pauseAll()
        case .resumeAll:
            store.resumeAll()
        case .toggleSpeedLimit:
            store.settings.speedLimitEnabled.toggle()
            store.applySpeedLimit()
        case .startQueue:
            store.startQueueNow()
        }
    }
}

/// Registers the shortcuts from Settings > Shortcuts with the system, so they work in any app. Uses Carbon's hot key
/// API, which needs no permission (unlike watching every key press).
@MainActor @Observable
final class GlobalShortcuts {
    static let shared = GlobalShortcuts()
    nonisolated private static let defaultsKey = "globalShortcuts"
    /// "ANCR": tells Anchor's hot keys apart from other apps' in the event.
    nonisolated private static let signature: OSType = 0x414E_4352

    private(set) var combos: [GlobalShortcutAction: KeyCombo] = [:]
    /// Shortcuts the system refused, almost always because another app already uses them.
    private(set) var unavailable: Set<GlobalShortcutAction> = []

    @ObservationIgnored private var registered: [GlobalShortcutAction: EventHotKeyRef] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var paused = false

    private init() {
        combos = Self.load(from: .standard)
    }

    func start() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr, hotKey.signature == GlobalShortcuts.signature else { return OSStatus(eventNotHandledErr) }
            let index = Int(hotKey.id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard GlobalShortcutAction.allCases.indices.contains(index) else { return }
                    GlobalShortcutAction.allCases[index].perform()
                }
            }
            return noErr
        }, 1, &spec, nil, &handler)
        registerAll()
    }

    /// Sets or clears an action's shortcut. A combination another action had moves to this one.
    func set(_ combo: KeyCombo?, for action: GlobalShortcutAction) {
        if let combo {
            for (other, existing) in combos where other != action && existing.keyCode == combo.keyCode && existing.modifiers == combo.modifiers {
                combos[other] = nil
            }
        }
        combos[action] = combo
        Self.save(combos, to: .standard)
        registerAll()
    }

    func clearAll() {
        combos = [:]
        Self.save(combos, to: .standard)
        registerAll()
    }

    /// While a shortcut is being recorded: lets every key through to the recorder.
    func pause() {
        paused = true
        unregisterAll()
    }

    func resume() {
        paused = false
        registerAll()
    }

    private func registerAll() {
        unregisterAll()
        guard !paused else { return }
        var refused: Set<GlobalShortcutAction> = []
        for (index, action) in GlobalShortcutAction.allCases.enumerated() {
            guard let combo = combos[action] else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: Self.signature, id: UInt32(index)),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { registered[action] = ref } else { refused.insert(action) }
        }
        unavailable = refused
    }

    private func unregisterAll() {
        registered.values.forEach { UnregisterEventHotKey($0) }
        registered = [:]
    }

    nonisolated static func load(from defaults: UserDefaults) -> [GlobalShortcutAction: KeyCombo] {
        guard let data = defaults.data(forKey: defaultsKey),
              let raw = try? JSONDecoder().decode([String: KeyCombo].self, from: data) else { return [:] }
        var combos: [GlobalShortcutAction: KeyCombo] = [:]
        for (key, combo) in raw {
            if let action = GlobalShortcutAction(rawValue: key), combo.isUsable { combos[action] = combo }
        }
        return combos
    }

    nonisolated static func save(_ combos: [GlobalShortcutAction: KeyCombo], to defaults: UserDefaults) {
        let raw = Dictionary(uniqueKeysWithValues: combos.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { defaults.set(data, forKey: defaultsKey) }
    }
}
