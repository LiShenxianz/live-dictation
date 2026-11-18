import AppKit
import ApplicationServices
import Carbon

final class TextDestination {
    let pid: pid_t?
    private let field: AXUIElement?

    private var keyboard: KeyboardText?
    private var selection: CFRange?
    private var anchor: CFIndex?
    private var committed = ""
    private var changed = false
    private var paused = false

    init() {
        pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        field = pid.flatMap(Self.focusedField)
        if let field, !Self.inWebEditor(field), Self.writable(field, kAXSelectedTextAttribute),
           Self.writable(field, kAXSelectedTextRangeAttribute) {
            selection = Self.range(field)
            anchor = selection?.location
        }
        if anchor == nil, let pid, AXIsProcessTrusted() { keyboard = KeyboardText(pid: pid) }
    }

    private static func inWebEditor(_ field: AXUIElement) -> Bool {
        var element = field
        for _ in 0..<36 {
            var role: CFTypeRef?, parent: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if (role as? String) == "AXWebArea" { return true }
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        return false
    }

    private static func focusedField(_ pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var element: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &element) == .success,
              let element, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    private static func writable(_ field: AXUIElement, _ attribute: String) -> Bool {
        var yes = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(field, attribute as CFString, &yes) == .success && yes.boolValue
    }

    private static func range(_ field: AXUIElement) -> CFRange? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(result as! AXValue, .cfRange, &r) && r.location >= 0 ? r : nil
    }

    private func textIn(_ field: AXUIElement, _ at: CFRange) -> String? {
        var r = at
        var result: CFTypeRef?
        guard let value = AXValueCreate(.cfRange, &r) else { return nil }
        if AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString, value, &result) == .success,
           let text = result as? String { return text }
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &result) == .success,
              let text = result as? NSString, r.location >= 0, r.length >= 0,
              r.location <= text.length, r.length <= text.length - r.location else { return nil }
        return text.substring(with: NSRange(location: r.location, length: r.length))
    }

    private func select(_ r: CFRange, in field: AXUIElement) -> Bool {
        var r = r
        guard let v = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    @discardableResult func update(_ text: String) -> Bool {
        if let keyboard { return keyboard.update(text) }
        guard !paused, let anchor, let selection, let field, let pid else { return false }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let current = Self.focusedField(pid), CFEqual(field, current),
              let actual = Self.range(field), actual.location == selection.location,
              actual.length == selection.length else { paused = true; return false }
        if text == committed { return true }
        let old = CFRange(location: anchor, length: committed.utf16.count)
        if changed && textIn(field, old) != committed { paused = true; return false }
        // Update only the revised suffix, leaving surrounding text and its formatting in place.
        let prefix = String(zip(committed, text).prefix(while: { $0.0 == $0.1 }).map { $0.0 })
        let start = anchor + prefix.utf16.count
        let edit = changed ? CFRange(location: start, length: old.length - prefix.utf16.count) : selection
        guard !changed || select(edit, in: field) else { paused = true; return false }
        let replacement = String(text.dropFirst(prefix.count))
        guard AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, replacement as CFString) == .success else {
            if changed { _ = select(selection, in: field) }
            return false
        }
        changed = true
        committed = text
        let caret = CFRange(location: anchor + text.utf16.count, length: 0)
        self.selection = caret
        if let actual = Self.range(field), actual.location == caret.location && actual.length == 0 { return true }
        if select(caret, in: field) { return true }
        paused = true
        return false
    }

    enum Outcome {
        case inserted, pasteSent, needsAccess, focusChanged, unavailable

        var message: String? {
            switch self {
            case .inserted, .pasteSent: return nil
            case .needsAccess: return "已复制。请在「辅助功能」中开启X-ASR 听写。"
            case .focusChanged: return "输入焦点已改变，文字已复制，可按 ⌘V。"
            case .unavailable: return "无法自动输入，文字已复制，可按 ⌘V。"
            }
        }
    }

    func insert(_ text: String) -> Outcome {
        func copy() {
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(text, forType: .string)
        }
        guard AXIsProcessTrusted() else { copy(); return .needsAccess }
        if let keyboard {
            if keyboard.update(text) { return .inserted }
            if keyboard.hasWritten || !keyboard.available { copy(); return .focusChanged }
        }
        if anchor != nil && update(text) { return .inserted }
        if changed || paused { copy(); return .focusChanged }
        guard let pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            copy()
            return .focusChanged
        }
        let current = Self.focusedField(pid)
        if let field, let current, !CFEqual(field, current) {
            copy()
            return .focusChanged
        }
        if let field, let current, CFEqual(field, current) {
            let attribute = kAXSelectedTextAttribute as CFString
            var writable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(field, attribute, &writable) == .success, writable.boolValue,
               AXUIElementSetAttributeValue(field, attribute, text as CFString) == .success {
                return .inserted
            }
        }
        copy()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return .unavailable }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        return .pasteSent
    }
}
