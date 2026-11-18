import AppKit
import ApplicationServices
import Carbon

/// Tracks the editing destination only during a user-started dictation session.
final class FocusFollowing {
    struct Spot: Equatable {
        let pid: pid_t
        let window: AXUIElement?
        let field: AXUIElement?
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.pid == rhs.pid && lhs.window == rhs.window && lhs.field == rhs.field
        }
        static func element(_ app: AXUIElement, _ key: String) -> AXUIElement? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app,key as CFString,&v) == .success,
                  let v,CFGetTypeID(v)==AXUIElementGetTypeID() else { return nil }
            return (v as! AXUIElement)
        }
        static func current() -> Self? {
            guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
            let a = AXUIElementCreateApplication(front.processIdentifier)
            return Self(pid:front.processIdentifier, window:element(a,kAXFocusedWindowAttribute),
                        field:element(a,kAXFocusedUIElementAttribute))
        }
        var editable: Bool {
            guard let field else { return false }
            var role: CFTypeRef?, subrole: CFTypeRef?, selection: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(field,kAXRoleAttribute as CFString,&role)
            _ = AXUIElementCopyAttributeValue(field,kAXSubroleAttribute as CFString,&subrole)
            guard subrole as? String != "AXSecureTextField" else { return false }
            let roleName = role as? String ?? ""
            let hasSelection = AXUIElementCopyAttributeValue(field,kAXSelectedTextRangeAttribute as CFString,&selection) == .success
            var writable = DarwinBoolean(false)
            _ = AXUIElementIsAttributeSettable(field,kAXValueAttribute as CFString,&writable)
            return ["AXTextArea","AXTextField","AXComboBox","AXSearchField"].contains(roleName)
                && (hasSelection || writable.boolValue)
        }
        static func textPointer() -> Bool {
            guard let cursor = NSCursor.currentSystem else { return false }
            return [NSCursor.iBeam, NSCursor.iBeamCursorForVerticalLayout].contains {
                cursor == $0 || (cursor.hotSpot == $0.hotSpot && cursor.image.tiffRepresentation == $0.image.tiffRepresentation)
            }
        }
        var permitsInitialInput: Bool {
            editable || (opaque && Self.textPointer())
        }
        var opaque: Bool {
            guard let field else { return true }
            var role: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(field,kAXRoleAttribute as CFString,&role)
            return ["AXWebArea","AXGroup","AXWindow","AXUnknown","AXApplication"].contains(role as? String ?? "")
        }
    }
    private var last = Spot.current()
    private var pending = false
    private var nextCheck = Date.distantPast
    private var blocked = false
    private var mouseHeld = false
    private var clicked = false
    private var timer: Timer?
    private var monitor: Any?
    private let pause: () -> Void
    private let resume: () -> Void

    init(pause: @escaping () -> Void,resume: @escaping () -> Void) {
        self.pause = pause; self.resume = resume
        monitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.keyDown]) { [weak self] e in
            guard let self else { return }
            switch e.type {
            case .leftMouseDown,.rightMouseDown:
                self.mouseHeld = true; self.clicked = false; self.blocked = false; self.interrupt()
            case .leftMouseUp,.rightMouseUp:
                self.mouseHeld = false; self.clicked = e.type == .leftMouseUp
                self.nextCheck = Date().addingTimeInterval(0.16)
            case .keyDown:
                guard e.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()),
                      e.keyCode != kVK_F20,
                      !(e.keyCode == kVK_ANSI_D && e.modifierFlags.contains([.control,.option])) else { return }
                self.clicked = false; self.blocked = false; self.interrupt()
            default: break
            }
        }
        let clock = Timer(timeInterval:0.12,repeats:true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(clock,forMode:.common)
        timer = clock
    }

    private func interrupt() {
        nextCheck = Date().addingTimeInterval(0.16)
        if !pending { pending = true; pause() }
    }
    func waitForAnotherTarget() {
        blocked = true
        interrupt()
    }
    func waitForInput() { interrupt() }

    private func poll() {
        let now = Spot.current()
        if now != last { last = now; blocked = false; interrupt() }
        guard pending, !blocked, !mouseHeld, Date() >= nextCheck, let now,
              now.editable || (clicked && now.opaque && Spot.textPointer()) else { return }
        pending = false; clicked = false; resume()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    deinit { stop() }
}
