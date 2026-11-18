import AppKit
import Carbon

/// Delivers text to the focused editor through its normal keyboard input path.
final class KeyboardText {
    private let pid: pid_t
    private var monitor: Any?
    private var activation: NSObjectProtocol?
    private var interrupted = false
    private var last = ""
    private let tag = Int64.random(in: 100_000...Int64(Int32.max))
    init(pid: pid_t) {
        self.pid = pid
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] e in
            guard let self, e.cgEvent?.getIntegerValueField(.eventSourceUserData) != self.tag else { return }
            if e.type == .keyDown && (e.keyCode == kVK_F20 ||
                (e.keyCode == kVK_ANSI_D && e.modifierFlags.contains([.control,.option]))) { return }
            self.interrupted = true
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != self.pid else { return }
            self.interrupted = true
        }
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
    }
    var available: Bool {
        !interrupted && AXIsProcessTrusted() && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }
    var hasWritten: Bool { !last.isEmpty }
    private func key(_ code: Int, _ flags: CGEventFlags = []) {
        for pressed in [true,false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: pressed) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: tag)
            e.post(tap: .cghidEventTap)
        }
    }

    func update(_ text: String) -> Bool {
        guard available else { return false }
        if text == last { return true }
        let equal = zip(last, text).prefix(while: { $0.0 == $0.1 }).count
        let replaced = String(last.dropFirst(equal))
        let addition = String(text.dropFirst(equal))
        let board = NSPasteboard.general
        if !replaced.isEmpty {
            // Check the selected suffix before replacing it in a custom editor.
            for _ in replaced { key(kVK_LeftArrow, .maskShift) }
            let count = board.changeCount
            key(kVK_ANSI_C, .maskCommand)
            for _ in 0..<35 {
                if board.changeCount != count { break }
                Thread.sleep(forTimeInterval:0.008)
            }
            guard available, board.changeCount != count, board.string(forType:.string) == replaced else {
                if available { key(kVK_RightArrow) }
                interrupted = true
                return false
            }
        }
        if addition.isEmpty {
            key(kVK_Delete)
        } else {
            for character in addition {
                guard available else { return false }
                let units = Array(String(character).utf16)
                for pressed in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: pressed) else { return false }
                    event.flags = []
                    event.setIntegerValueField(.eventSourceUserData, value: tag)
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    event.post(tap: .cghidEventTap)
                }
            }
        }
        last = text
        return true
    }
}
