import AppKit
import Carbon.HIToolbox

/// A key combination the user recorded, e.g. ⌥⌘A.
struct KeyboardShortcutSpec: Codable, Equatable {
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags` raw value, limited to ⌃⌥⇧⌘.
    var modifiers: UInt
    /// The key as typed when it was recorded ("A", "Space", "F5").
    var keyName: String

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var displayName: String {
        let flags = modifierFlags
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + keyName
    }

    /// Builds a shortcut from a key press, or nil if it can't be a global shortcut (no
    /// ⌃, ⌥ or ⌘, unless it's a function key).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let name = Self.name(for: event)
        let isFunctionKey = Self.functionKeys[Int(event.keyCode)] != nil
        guard !name.isEmpty, isFunctionKey || !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        keyCode = event.keyCode
        modifiers = flags.rawValue
        keyName = name
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    private static func name(for event: NSEvent) -> String {
        let code = Int(event.keyCode)
        if let name = functionKeys[code] ?? namedKeys[code] { return name }
        return (event.charactersIgnoringModifiers ?? "").uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A system-wide shortcut that toggles the panel, registered with Carbon's hot key API, which
/// (unlike a global event monitor) needs no Accessibility permission and swallows the keys.
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private static let defaultsKey = "panelShortcut"

    var action: () -> Void = {}

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    private(set) var shortcut: KeyboardShortcutSpec? = {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(KeyboardShortcutSpec.self, from: data)
    }()

    /// Registers the saved shortcut, if any. Call once at launch.
    func start() {
        installHandler()
        if let shortcut, !register(shortcut) { unregister() }
    }

    /// Saves and registers `shortcut` (nil clears it). Returns false if the system refused it,
    /// typically because another app already uses that combination.
    @discardableResult
    func setShortcut(_ shortcut: KeyboardShortcutSpec?) -> Bool {
        let previous = self.shortcut
        unregister()
        if let shortcut, !register(shortcut) {
            if let previous { _ = register(previous) }
            return false
        }
        self.shortcut = shortcut
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
        return true
    }

    private func register(_ shortcut: KeyboardShortcutSpec) -> Bool {
        let flags = shortcut.modifierFlags
        var carbonModifiers: UInt32 = 0
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        let id = EventHotKeyID(signature: OSType(0x414E_444D), id: 1) // "ANDM"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKey = ref
        return true
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            // Carbon delivers hot key events on the main thread.
            MainActor.assumeIsolated { GlobalHotKey.shared.action() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
