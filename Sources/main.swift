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

final class DictationApp: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let brand = NSMenuItem(title: "神仙语音转录", action: nil, keyEquivalent: "")
    let action = NSMenuItem(title: "开始听写（⌃⌥D）", action: #selector(toggle), keyEquivalent: "")
    let info = NSMenuItem(title: "X-ASR · 本机识别", action: nil, keyEquivalent: "")
    var hotkey: EventHotKeyRef?
    private let microphoneKey = MicrophoneKey()
    private var microphoneHotkey: EventHotKeyRef?
    private let light = MicrophoneLight()
    private var live: LiveInput?
    private var following: FocusFollowing?
    private var generation = 0
    var busy = false
    private var destination: TextDestination?
    var shortcutTitle = "开始听写（⌃⌥D）"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.addItem(brand)
        menu.addItem(.separator())
        item.autosaveName = "LiveDictation"
        item.isVisible = true
        let image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "神仙语音转录")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.setAccessibilityLabel("神仙语音转录")
        action.target = self
        menu.addItem(action)
        menu.addItem(info)
        menu.addItem(.separator())
        menu.addItem(withTitle: "授权自动输入…", action: #selector(requestPasteAccess), keyEquivalent: "").target = self
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = menu
        setStatus("听写")
        item.button?.toolTip = "神仙语音转录 · Control + Option + D"
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            Unmanaged<DictationApp>.fromOpaque(context).takeUnretainedValue().toggle()
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), nil)
        let key = EventHotKeyID(signature: 0x58415352, id: 1)
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey), key, GetApplicationEventTarget(), 0, &hotkey)
        let microphoneID = EventHotKeyID(signature: 0x58415352, id: 2)
        let microphoneRegistered = RegisterEventHotKey(UInt32(kVK_F20), 0, microphoneID, GetApplicationEventTarget(), 0, &microphoneHotkey)
        if installed == noErr && microphoneRegistered == noErr && microphoneKey.install() {
            shortcutTitle = "开始听写（麦克风键）"
            item.button?.toolTip = "神仙语音转录 · 按麦克风键开始或结束"
        } else {
            if let microphoneHotkey { UnregisterEventHotKey(microphoneHotkey) }
            if installed == noErr && registered == noErr {
                info.title = "麦克风键绑定失败，可用 ⌃⌥D"
            } else {
                shortcutTitle = "开始听写"
                info.title = "快捷键不可用，请从此菜单启动"
            }
        }
        action.title = shortcutTitle
        if !AXIsProcessTrusted() && !UserDefaults.standard.bool(forKey: "offeredTextInsertionAccess") {
            UserDefaults.standard.set(true, forKey: "offeredTextInsertionAccess")
            requestPasteAccess()
        }
    }

    private func setStatus(_ status: String) {
        brand.title = status == "听写" ? "神仙语音转录" : "神仙语音转录 · " + status
        item.button?.toolTip = brand.title
        item.button?.setAccessibilityValue(status)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        item.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return false
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
                action.title = shortcutTitle
                light.hide()
                return
            }
        }
        if let live {
            busy = true
            setStatus("正在完成…")
            light.hide()
            live.finish()
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
                    resume: { [weak self] in self?.resumeAtFocus() })
                if FocusFollowing.Spot.current()?.permitsInitialInput == true {
                    self.resumeAtFocus()
                } else {
                    self.following?.waitForInput()
                }
            }
        }
    }

    private func pauseForFocus() {
        generation += 1
        light.hide()
        destination = nil
        let old = live
        live = nil
        old?.finish()
        setStatus("等待输入框")
    }

    private func resumeAtFocus() {
        guard following != nil, live == nil else { return }
        destination = TextDestination()
        light.show()
        startListening()
    }

    private func startListening() {
        generation += 1
        let current = generation
        let session = LiveInput(update: { [weak self] text in
            guard let self, self.generation == current else { return }
            if self.destination?.update(text) != true, !self.busy {
                self.following?.waitForAnotherTarget()
            }
        }, level: { [weak self] audible in
            guard let self, self.generation == current, !self.busy, self.live != nil else { return }
            self.light.signal(audible)
            self.setStatus(audible ? "🟢 听写中" : "● 录音中")
        }, end: { [weak self] result in
            guard let self, self.generation == current else { return }
            self.following?.stop()
            self.following = nil
            self.light.hide()
            self.live = nil
            self.busy = false
            self.action.title = self.shortcutTitle
            self.setStatus("听写")
            switch result {
            case .success(let text) where text.isEmpty:
                self.destination?.update("")
                self.info.title = "没有识别到语音"
            case .success(let text):
                let outcome = self.destination?.insert(text) ?? .unavailable
                if let message = outcome.message {
                    self.setStatus("已复制 · ⌘V")
                    self.info.title = message
                    if outcome == .needsAccess { self.requestPasteAccess() }
                    return
                }
                self.info.title = outcome == .inserted ? "已写入当前输入框" : "已向当前输入框发送粘贴"
            case .failure(let error): self.alert(error.localizedDescription)
            }
        })
        do {
            live = session
            try session.start(node: nodeURL, script: Bundle.main.url(forResource: "transcribe", withExtension: "cjs")!)
            setStatus("● 录音中")
            action.title = "结束并输入文字"
        } catch {
            following?.stop()
            following = nil
            light.hide()
            live = nil
            alert(error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        following?.stop()
        microphoneKey.remove()
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
