import AppKit
import Carbon

final class ShortcutEditor: NSObject {
    private let binding: ShortcutBinding
    private let alert = NSAlert()
    private let field = NSTextField(labelWithString: "")
    private var pending: DictationShortcut

    init(_ binding: ShortcutBinding) {
        self.binding = binding
        pending = binding.choice
        super.init()
        alert.messageText = "自定义听写快捷键"
        alert.informativeText = "按下新组合键或单个 F1–F19，然后点「保存」。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "恢复默认")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 25)
        field.alignment = .center
        alert.accessoryView = field
        selectCurrent()
    }

    private func select(_ shortcut: DictationShortcut) {
        pending = shortcut
        field.stringValue = shortcut.title
        field.font = .systemFont(ofSize: 19, weight: .medium)
        field.textColor = .labelColor
        field.setAccessibilityLabel("待保存的快捷键")
        alert.buttons[0].isEnabled = true
    }
    func selectCurrent() { select(binding.choice) }

    @objc private func resetChoice() {
        select(.standard)
    }

    @objc private func saveChoice() {
        if binding.apply(pending) { NSApp.stopModal(); return }
        showError("此组合不可用，请换一组按键")
    }

    private func showError(_ text: String) {
        field.setAccessibilityLabel("快捷键提示")
        field.font = .systemFont(ofSize: 13)
        field.textColor = .systemRed
        field.stringValue = text
    }
    @objc private func cancelChoice() { NSApp.stopModal() }

    func run() {
        alert.layout()
        let window = alert.window
        let actions = [#selector(saveChoice), #selector(cancelChoice), #selector(resetChoice)]
        for (button, action) in zip(alert.buttons, actions) {
            button.target = self
            button.action = action
        }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === window else { return event }
            let mods = event.modifierFlags.intersection([.control,.option,.shift,.command])
            if mods.isEmpty && [kVK_Escape,kVK_Return,kVK_Tab].contains(Int(event.keyCode)) { return event }
            if let shortcut = DictationShortcut.capture(event) { self.select(shortcut) }
            else {
                self.alert.buttons[0].isEnabled = false
                self.showError("请加入 ⌘、⌥ 或 ⌃，或使用功能键")
            }
            return nil
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) }; window.orderOut(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
    }
}
