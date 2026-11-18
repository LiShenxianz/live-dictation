import AppKit
import Carbon

struct DictationShortcut: Codable {
    let code: UInt32
    let modifiers: UInt32
    let keyLabel: String
    static let standard = Self(code: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey), keyLabel: "D")
    private static let functions = [kVK_F1,kVK_F2,kVK_F3,kVK_F4,kVK_F5,kVK_F6,kVK_F7,kVK_F8,kVK_F9,kVK_F10,
                                    kVK_F11,kVK_F12,kVK_F13,kVK_F14,kVK_F15,kVK_F16,kVK_F17,kVK_F18,kVK_F19]
    private static let masks: [(NSEvent.ModifierFlags, Int, String)] = [
        (.control,controlKey,"⌃"), (.option,optionKey,"⌥"), (.shift,shiftKey,"⇧"), (.command,cmdKey,"⌘")
    ]
    private static func flags(_ event: NSEvent) -> UInt32 {
        masks.reduce(0) { $0 | (event.modifierFlags.contains($1.0) ? UInt32($1.1) : 0) }
    }
    var title: String { Self.masks.filter { modifiers & UInt32($0.1) != 0 }.map { $0.2 }.joined() + keyLabel }
    func matches(_ event: NSEvent) -> Bool { UInt32(event.keyCode) == code && Self.flags(event) == modifiers }

    static func capture(_ event: NSEvent) -> Self? {
        let key = Int(event.keyCode)
        let mods = flags(event)
        guard key != kVK_F20 else { return nil }
        if let i = functions.firstIndex(of: key) {
            return Self(code: UInt32(key), modifiers: mods, keyLabel: "F\(i + 1)")
        }
        guard mods & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
        let special = [kVK_Space:"空格", kVK_Return:"↩", kVK_ANSI_KeypadEnter:"⌤", kVK_Tab:"⇥", kVK_Delete:"⌫",
                       kVK_ForwardDelete:"⌦", kVK_LeftArrow:"←", kVK_RightArrow:"→", kVK_UpArrow:"↑", kVK_DownArrow:"↓",
                       kVK_Home:"↖", kVK_End:"↘", kVK_PageUp:"⇞", kVK_PageDown:"⇟", kVK_Escape:"⎋"]
        guard let label = special[key] ?? event.characters(byApplyingModifiers: [])?.uppercased(), !label.isEmpty else { return nil }
        return Self(code: UInt32(key), modifiers: mods, keyLabel: label)
    }
}

final class ShortcutBinding {
    static let shared = ShortcutBinding()
    static let signature: OSType = 0x58415352
    static let micID: UInt32 = 2
    private let store: UserDefaults
    private let pref = "dictationKeyboardShortcut"
    private(set) var choice: DictationShortcut
    private(set) var keyboardID: UInt32 = 1
    private var keyboard: EventHotKeyRef?
    private let mic = MicrophoneKey()
    private var micRef: EventHotKeyRef?
    var hasKeyboard: Bool { keyboard != nil }
    var hasMic: Bool { micRef != nil }

    init(store: UserDefaults = .standard) {
        self.store = store
        choice = store.data(forKey: pref).flatMap { try? JSONDecoder().decode(DictationShortcut.self, from: $0) } ?? .standard
    }
    func start() {
        _ = apply(choice)
        let id = EventHotKeyID(signature: Self.signature, id: Self.micID)
        if RegisterEventHotKey(UInt32(kVK_F20), 0, id, GetApplicationEventTarget(), 0, &micRef) == noErr,
           !mic.install(), let micRef {
            UnregisterEventHotKey(micRef)
            self.micRef = nil
        }
    }
    func apply(_ shortcut: DictationShortcut) -> Bool {
        if keyboard != nil && choice.code == shortcut.code && choice.modifiers == shortcut.modifiers { return true }
        var next: EventHotKeyRef?
        let nextID: UInt32 = keyboardID == 1 ? 3 : 1
        let id = EventHotKeyID(signature: Self.signature, id: nextID)
        guard RegisterEventHotKey(shortcut.code, shortcut.modifiers, id, GetApplicationEventTarget(),
                                  UInt32(kEventHotKeyExclusive), &next) == noErr, let next else { return false }
        if let keyboard { UnregisterEventHotKey(keyboard) }
        keyboard = next
        keyboardID = nextID
        choice = shortcut
        store.set(try? JSONEncoder().encode(shortcut), forKey: pref)
        return true
    }
    func matches(_ event: NSEvent) -> Bool {
        (hasKeyboard && choice.matches(event)) || (hasMic && event.keyCode == kVK_F20)
    }
    func stop() {
        if let keyboard { UnregisterEventHotKey(keyboard); self.keyboard = nil }
        if let micRef { UnregisterEventHotKey(micRef); self.micRef = nil }
        mic.remove()
    }
}
