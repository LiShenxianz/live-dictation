import AppKit
import AVFoundation

final class MicrophoneMenu: NSObject, NSMenuDelegate {
    let item = NSMenuItem(title: "麦克风", action: nil, keyEquivalent: "")
    private let menu = NSMenu(title: "麦克风")
    private let preferenceKey = "dictationMicrophone"
    private let changeInput: (AVCaptureDevice?) throws -> Void

    init(changeInput: @escaping (AVCaptureDevice?) throws -> Void) {
        self.changeInput = changeInput
        super.init()
        item.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        item.submenu = menu
        menu.delegate = self
        refreshTitle()
    }

    func refreshTitle(recordingDeviceName: String? = nil) {
        let missingName = preference?["name"].map { $0 + "（未连接）" } ?? "无可用设备"
        let name = recordingDeviceName ?? captureDevice()?.localizedName ?? missingName
        item.title = "麦克风：" + name
    }

    private var preference: [String: String]? {
        UserDefaults.standard.dictionary(forKey: preferenceKey) as? [String: String]
    }

    func captureDevice() -> AVCaptureDevice? {
        guard let id = preference?["id"] else { return AVCaptureDevice.default(for: .audio) }
        return Self.connectedDevice(id)
    }

    private static func connectedDevice(_ id: String) -> AVCaptureDevice? {
        guard let device = AVCaptureDevice(uniqueID: id), device.isConnected, device.hasMediaType(.audio) else { return nil }
        return device
    }

    var unavailableMessage: String {
        if let name = preference?["name"] { return "麦克风「" + name + "」未连接，请在菜单中重新选择。" }
        return "找不到系统默认麦克风，请检查系统声音输入。"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let saved = preference
        let id = saved?["id"]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        menu.removeAllItems()
        let automatic = addChoice("跟随系统默认", id: nil, checked: id == nil)
        automatic.subtitle = AVCaptureDevice.default(for: .audio)?.localizedName
        if !devices.isEmpty || id != nil { menu.addItem(.separator()) }
        for device in devices {
            _ = addChoice(device.localizedName, id: device.uniqueID, checked: id == device.uniqueID)
        }
        if let id, !devices.contains(where: { $0.uniqueID == id }) {
            let missing = menu.addItem(withTitle: (saved?["name"] ?? "麦克风") + "（未连接）", action: nil, keyEquivalent: "")
            missing.state = .on
        }
    }

    private func addChoice(_ name: String, id: String?, checked: Bool) -> NSMenuItem {
        let choice = menu.addItem(withTitle: name, action: #selector(selectInput(_:)), keyEquivalent: "")
        choice.target = self
        choice.representedObject = id
        choice.state = checked ? .on : .off
        return choice
    }

    @objc private func selectInput(_ sender: NSMenuItem) {
        let id = sender.representedObject as? String
        do {
            if let id {
                guard let device = Self.connectedDevice(id) else {
                    throw NSError(domain: "MicrophoneMenu", code: 1, userInfo: [NSLocalizedDescriptionKey: "这个麦克风已断开，请重新选择。"])
                }
                try changeInput(device)
                UserDefaults.standard.set(["id": id, "name": device.localizedName], forKey: preferenceKey)
            } else {
                try changeInput(AVCaptureDevice.default(for: .audio))
                UserDefaults.standard.removeObject(forKey: preferenceKey)
            }
            refreshTitle()
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法切换麦克风"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
