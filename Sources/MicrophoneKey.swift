import AppKit
import IOKit.hidsystem

final class MicrophoneKey {
    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private let key = "UserKeyMapping" as CFString
    private let source = "HIDKeyboardModifierMappingSrc"
    private let destination = "HIDKeyboardModifierMappingDst"
    private let voiceCommand: UInt64 = 0xC000000CF
    private let f20: UInt64 = 0x70000006F
    private var active = false

    private var keyboard: IOHIDServiceClient? {
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return services.first {
            IOHIDServiceClientConformsTo($0, 1, 6) != 0 &&
            IOHIDServiceClientCopyProperty($0, "Product" as CFString) as? String == "Apple Internal Keyboard / Trackpad"
        }
    }

    private func mappings(_ service: IOHIDServiceClient) -> [[String: UInt64]]? {
        guard let value = IOHIDServiceClientCopyProperty(service, key) else { return [] }
        return value as? [[String: UInt64]]
    }

    func install() -> Bool {
        guard let service = keyboard, var all = mappings(service) else { return false }
        let entry = [source: voiceCommand, destination: f20]
        if !all.contains(entry) {
            guard !all.contains(where: { $0[source] == voiceCommand || $0[destination] == f20 }) else { return false }
            all.append(entry)
            _ = IOHIDServiceClientSetProperty(service, key, all as CFArray)
        }
        active = mappings(service)?.contains(entry) == true
        return active
    }

    func remove() {
        let entry = [source: voiceCommand, destination: f20]
        guard active, let service = keyboard, let all = mappings(service), all.contains(entry) else { return }
        _ = IOHIDServiceClientSetProperty(service, key, all.filter { $0 != entry } as CFArray)
        active = false
    }
}
