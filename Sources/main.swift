import AppKit
import AVFoundation
import Carbon

private let nodeURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/node")

func transcribe(_ url: URL) throws -> String {
    let process = Process()
    process.executableURL = nodeURL
    process.arguments = [Bundle.main.url(forResource: "transcribe", withExtension: "cjs")!.path, url.path]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "XASR", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法加载内置模型，请从 Releases 重新安装完整的 App。"])
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

final class DictationApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let brand = NSMenuItem(title: "神仙语音转录", action: nil, keyEquivalent: "")
    private lazy var header = MenuStatusHeader(title: brand.title, icon: NSApp.applicationIconImage)
    let action = NSMenuItem(title: "开始听写（⌃⌥D）", action: #selector(toggle), keyEquivalent: "")
    private let shortcuts = ShortcutBinding.shared
    private var shortcutEditor: ShortcutEditor?
    private var hotkeysAvailable = false
    private let settings = NSMenuItem(title: "自定义快捷键…", action: #selector(changeShortcut), keyEquivalent: "")
    private let access = NSMenuItem()
    private var status = "听写"
    private let light = MicrophoneLight()
    private let cues = RecordingCues()
    private var live: LiveInput?
    private var following: FocusFollowing?
    private var generation = 0
    var busy = false
    private var destination: TextDestination?
    private var pendingText: String?
    private func updateAction(recording: Bool = false) {
        action.title = recording ? "结束听写" : "开始听写"
        let keys = [shortcuts.hasMic ? "麦克风键" : nil, shortcuts.hasKeyboard ? shortcuts.choice.title : nil]
        action.subtitle = keys.compactMap { $0 }.joined(separator: "  /  ")
        action.image = NSImage(systemSymbolName: recording ? "stop.circle" : "mic", accessibilityDescription: nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.minimumWidth = 220
        brand.view = header
        menu.addItem(brand)
        menu.addItem(.separator())
        item.autosaveName = "LiveDictation"
        item.isVisible = true
        let image = Bundle.main.url(forResource: "MenuMicrophone", withExtension: "svg")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "神仙语音转录")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.setAccessibilityLabel("神仙语音转录")
        action.target = self
        menu.addItem(action)
        menu.addItem(.separator())
        settings.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        settings.target = self
        menu.addItem(settings)
        menu.delegate = self
        menu.addItem(access)
        access.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = menu
        setStatus("听写")
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        hotkeysAvailable = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == ShortcutBinding.signature else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<DictationApp>.fromOpaque(context).takeUnretainedValue()
            if let editor = app.shortcutEditor {
                if id.id == app.shortcuts.keyboardID { editor.selectCurrent() }
            } else if id.id == app.shortcuts.keyboardID || id.id == ShortcutBinding.micID { app.toggle() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), nil) == noErr
        if hotkeysAvailable { shortcuts.start() }
        refreshAccess()
        updateAction()
        if !AXIsProcessTrusted() && !UserDefaults.standard.bool(forKey: "offeredTextInsertionAccess") {
            UserDefaults.standard.set(true, forKey: "offeredTextInsertionAccess")
            requestPasteAccess()
        }
    }

    private func setStatus(_ status: String) {
        self.status = status
        refreshAccess()
        item.button?.contentTintColor = ["🟢 听写中", "● 录音中"].contains(status) ? .systemGreen : nil
        item.button?.setAccessibilityValue(status)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        item.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return false
    }

    @objc private func changeShortcut() {
        guard shortcutEditor == nil else { return }
        guard hotkeysAvailable else { alert("快捷键服务未启动，请重新打开 App。"); return }
        let editor = ShortcutEditor(shortcuts)
        shortcutEditor = editor
        editor.run()
        shortcutEditor = nil
        if following == nil && live == nil { updateAction() }
        refreshAccess()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshAccess()
    }

    private func refreshAccess() {
        let granted = AXIsProcessTrusted()
        access.title = granted ? "自动输入：已授权" : "自动输入：未授权"
        access.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [granted ? .systemGreen : .systemRed]))
        access.action = #selector(openAccessSettings)
        let subtitle: String
        if status != "听写" {
            subtitle = status
        } else if !granted {
            subtitle = "等待授权 · 自动输入"
        } else {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                subtitle = "就绪"
            case .notDetermined: subtitle = "首次开麦时需授权"
            default: subtitle = "麦克风未授权"
            }
        }
        brand.subtitle = subtitle
        header.update(subtitle)
        item.button?.toolTip = brand.title + " · " + subtitle
    }

    @objc private func openAccessSettings() {
        if !AXIsProcessTrusted() { requestPasteAccess() }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func requestPasteAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func alert(_ message: String) {
        let box = NSAlert()
        box.messageText = "神仙语音转录"
        box.informativeText = message
        box.runModal()
    }

    @objc func toggle() {
        guard !busy else { return }
        if following != nil {
            following?.stop()
            following = nil
            if live == nil {
                setStatus("听写")
                updateAction()
                light.hide()
                cues.end()
                return
            }
        }
        if let live {
            busy = true
            setStatus("正在完成…")
            live.finish()
            light.hide()
            cues.end()
            return
        }
        busy = true
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.busy = false
                guard granted else {
                    self.light.hide()
                    self.alert("请到「隐私与安全性 → 麦克风」允许神仙语音转录。")
                    return
                }
                self.following = FocusFollowing(pause: { [weak self] in self?.pauseForFocus() },
                    resume: { [weak self] in self?.resumeAtFocus() },
                    beginEdit: { [weak self] in
                        self?.destination = nil
                        self?.pendingText = nil
                        self?.live?.resetSegment()
                    }, finishEdit: { [weak self] in
                        guard let self else { return }
                        self.destination = TextDestination()
                        if let text = self.pendingText { self.writePartial(text) }
                        self.pendingText = nil
                    })
                self.following?.typed = { [weak self] in self?.light.inputAdvanced(typing: true) }
                self.following?.inputChanged = { [weak self] spot in
                    if let spot, spot.permitsInitialInput { self?.light.show(at: spot, immediately: false) }
                    else { self?.light.hide() }
                }
                self.following?.updateIndicator = { [weak self] in self?.light.follow($0) }
                if FocusFollowing.Spot.current()?.permitsInitialInput == true {
                    self.resumeAtFocus(manual: true)
                } else {
                    self.following?.waitForInput()
                }
            }
        }
    }

    private func pauseForFocus() {
        generation += 1
        pendingText = nil
        destination = nil
        let old = live
        live = nil
        old?.finish()
        light.hide()
        setStatus("等待输入框")
        updateAction(recording: true)
    }

    private func resumeAtFocus(manual: Bool = false) {
        guard following != nil, live == nil else { return }
        if !light.listening { light.show(immediately: manual) }
        destination = TextDestination()
        startListening()
    }

    private func writePartial(_ text: String) {
        guard let destination else { pendingText = text; return }
        if !destination.update(text) && !busy { following?.waitForAnotherTarget() }
    }

    private func startListening() {
        generation += 1
        let current = generation
        let session = LiveInput(update: { [weak self] text in
            guard let self, self.generation == current else { return }
            if !self.busy && !text.isEmpty { self.light.inputAdvanced() }
            self.writePartial(text)
        }, level: { [weak self] audible in
            guard let self, self.generation == current, !self.busy, self.live != nil else { return }
            self.setStatus(audible ? "🟢 听写中" : "● 录音中")
        }, end: { [weak self] result in
            guard let self, self.generation == current else { return }
            self.following?.stop()
            self.following = nil
            self.light.hide()
            self.cues.end()
            self.live = nil
            self.busy = false
            self.updateAction()
            self.setStatus("听写")
            switch result {
            case .success(let text) where text.isEmpty:
                self.destination?.update("")
            case .success(let text):
                let outcome = self.destination?.insert(text) ?? .unavailable
                if let message = outcome.message {
                    self.item.button?.toolTip = message
                    if outcome == .needsAccess { self.requestPasteAccess() }
                    return
                }
            case .failure(let error): self.alert(error.localizedDescription)
            }
        })
        do {
            live = session
            try session.start(node: nodeURL, script: Bundle.main.url(forResource: "transcribe", withExtension: "cjs")!)
            guard session.isRecording else { return }
            cues.begin()
            setStatus("● 录音中")
            updateAction(recording: true)
        } catch {
            following?.stop()
            following = nil
            light.hide()
            cues.end()
            live = nil
            alert(error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        following?.stop()
        shortcuts.stop()
        live?.finish()
    }
}

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--transcribe" {
    do { print(try transcribe(URL(fileURLWithPath: CommandLine.arguments[2]))) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else {
    signal(SIGPIPE, SIG_IGN)
    let app = NSApplication.shared
    let delegate = DictationApp()
    app.delegate = delegate
    app.run()
}
