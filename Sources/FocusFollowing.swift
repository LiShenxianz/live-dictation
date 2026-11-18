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
        private static var accessibilityPID: pid_t?
        private static var lastAccessibilityAttempt = Date.distantPast
        static func current() -> Self? {
            guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
            let a = AXUIElementCreateApplication(front.processIdentifier)
            var field = element(a, kAXFocusedUIElementAttribute)
            if accessibilityPID != front.processIdentifier || (field == nil && Date().timeIntervalSince(lastAccessibilityAttempt) >= 3) {
                lastAccessibilityAttempt = Date()
                accessibilityPID = front.processIdentifier
                let manual = AXUIElementSetAttributeValue(a, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                if manual == .attributeUnsupported, let url = front.bundleURL,
                   let principal = Bundle(url: url)?.object(forInfoDictionaryKey: "NSPrincipalClass") as? String,
                   principal.hasSuffix("CrApplication") {
                    // Chromium enables inline glyph geometry asynchronously after this request.
                    _ = AXUIElementSetAttributeValue(a, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                }
                field = element(a, kAXFocusedUIElementAttribute)
            }
            if field == nil, let focused = element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) {
                var owner: pid_t = 0
                if AXUIElementGetPid(focused, &owner) == .success, owner == front.processIdentifier { field = focused }
            }
            return Self(pid:front.processIdentifier, window:element(a,kAXFocusedWindowAttribute), field:field)
        }
        var editable: Bool {
            guard let field else { return false }
            var role: CFTypeRef?, subrole: CFTypeRef?, selection: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(field,kAXRoleAttribute as CFString,&role)
            _ = AXUIElementCopyAttributeValue(field,kAXSubroleAttribute as CFString,&subrole)
            let roleName = role as? String ?? ""
            guard subrole as? String != "AXSecureTextField",
                  ["AXTextArea","AXTextField","AXComboBox","AXSearchField"].contains(roleName) else { return false }
            if AXUIElementCopyAttributeValue(field,kAXSelectedTextRangeAttribute as CFString,&selection) == .success { return true }
            var writable = DarwinBoolean(false)
            _ = AXUIElementIsAttributeSettable(field,kAXValueAttribute as CFString,&writable)
            return writable.boolValue
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
    private var editing = false
    private var nextCheck = Date.distantPast
    private var blocked = false
    private var mouseHeld = false
    private var clicked = false
    private var timer: Timer?
    private var monitor: Any?
    private let pause: () -> Void
    private let resume: () -> Void

    var typed: (() -> Void)?
    var inputChanged: ((Spot?) -> Void)?
    var updateIndicator: ((Spot?) -> Void)?
    private let beginEdit: () -> Void
    private let finishEdit: () -> Void

    init(pause: @escaping () -> Void, resume: @escaping () -> Void,
         beginEdit: @escaping () -> Void, finishEdit: @escaping () -> Void) {
        self.beginEdit = beginEdit
        self.finishEdit = finishEdit
        self.pause = pause; self.resume = resume
        monitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.keyDown]) { [weak self] e in
            guard let self else { return }
            switch e.type {
            case .leftMouseDown,.rightMouseDown:
                self.mouseHeld = true; self.clicked = false; self.blocked = false; self.observeEdit()
            case .leftMouseUp,.rightMouseUp:
                self.mouseHeld = false; self.clicked = e.type == .leftMouseUp
                self.nextCheck = Date().addingTimeInterval(0.16)
            case .keyDown:
                guard e.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()),
                      !ShortcutBinding.shared.matches(e) else { return }
                if Self.isTyping(e) { self.typed?() }
                self.clicked = false; self.blocked = false; self.observeEdit()
            default: break
            }
        }
        let clock = Timer(timeInterval:0.12,repeats:true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(clock,forMode:.common)
        timer = clock
    }

    private static func isTyping(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty else { return false }
        if [kVK_Delete, kVK_ForwardDelete, kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)) { return true }
        guard let characters = event.charactersIgnoringModifiers else { return false }
        return characters.unicodeScalars.contains { $0.value >= 32 && !(0xF700...0xF8FF).contains($0.value) }
    }

    private func observeEdit() {
        nextCheck = Date().addingTimeInterval(0.12)
        if !pending && !editing { editing = true; beginEdit() }
    }

    private func interrupt() {
        editing = false
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
        if now != last {
            last = now
            blocked = false
            interrupt()
            inputChanged?(now)
        } else { updateIndicator?(now) }
        guard !blocked, !mouseHeld, Date() >= nextCheck, let now else { return }
        if editing && !pending {
            editing = false
            if now.editable || (now.opaque && (!clicked || Spot.textPointer())) {
                finishEdit()
            } else {
                interrupt()
            }
        } else if pending && now.permitsInitialInput {
            pending = false; clicked = false; resume()
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    deinit { stop() }
}
