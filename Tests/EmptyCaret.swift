import AppKit

// Run from the repository root on macOS with Chrome and Accessibility access for the runner.
// swiftc -O Tests/EmptyCaret.swift Sources/{IndicatorPlacement,RenderedCaret,FocusFollowing,DictationShortcut,MicrophoneKey}.swift -o /tmp/check-empty-caret && /tmp/check-empty-caret
@main
struct EmptyCaretTest {
    static func reference(in node: AXUIElement) -> AXUIElement? {
        if referenceName(node) != nil { return node }
        for child in IndicatorPlacement.attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let button = reference(in: child) { return button }
        }
        return nil
    }

    static func referenceName(_ node: AXUIElement) -> String? {
        for key in ["AXDescription", "AXTitle"] {
            if let name = IndicatorPlacement.attribute(node, key) as? String, name.hasPrefix("Caret reference ") { return name }
        }
        return nil
    }

    static func eventually(_ check: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: 12)
        repeat {
            if check() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    static func run(chrome: URL, basic: Bool) throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("empty-caret.html")
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: profile) }
        let browser = Process()
        browser.executableURL = chrome
        browser.arguments = ["--user-data-dir=" + profile.path, "--no-first-run", "--no-default-browser-check",
                             "--disable-background-timer-throttling", basic ? "--force-renderer-accessibility=basic" : "--force-renderer-accessibility",
                             "--app=" + fixture.absoluteString]
        browser.standardOutput = FileHandle.nullDevice
        browser.standardError = FileHandle.nullDevice
        try browser.run()
        defer {
            if browser.isRunning { browser.terminate() }
            browser.waitUntilExit()
        }

        let app = AXUIElementCreateApplication(browser.processIdentifier)
        var targetWindow: AXUIElement?, targetButton: AXUIElement?
        guard eventually({
            targetWindow = FocusFollowing.Spot.element(app, kAXFocusedWindowAttribute)
            targetButton = targetWindow.flatMap { reference(in: $0) }
            return targetButton != nil
        }), let window = targetWindow, let button = targetButton else { throw failure("Test editor did not open") }
        for index in 0..<7 {
            var outcome = "case \(index) did not activate"
            guard eventually({
                let current = referenceName(button) != nil ? button : reference(in: window)
                guard let current, let name = referenceName(current), name.hasPrefix("Caret reference \(index) "),
                      let ref = IndicatorPlacement.frame(of: current),
                      let field = FocusFollowing.Spot.element(app, kAXFocusedUIElementAttribute) else { return false }
                let spot = FocusFollowing.Spot(pid: browser.processIdentifier, window: window, field: field)
                guard let screen = NSScreen.screens.first else { return false }
                guard let p = IndicatorPlacement.origin(for: spot) else {
                    // Chromium can omit an insertion rectangle for a trailing empty paragraph.
                    outcome = name + " returned no caret"
                    return index >= 5 && referenceName(current) == name
                }
                let dx = p.x - ref.minX
                let dy = screen.frame.maxY - p.y - IndicatorPlacement.side - ref.minY
                outcome = "\(name) dx=\(dx) dy=\(dy)"
                return referenceName(current) == name && abs(dx - 5) <= 1 && abs(dy - 2) <= 1
            }) else { throw failure(outcome) }
            print(basic ? "basic" : "full", outcome)
        }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "EmptyCaretTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func verify() throws {
        _ = NSApplication.shared
        guard AXIsProcessTrusted(), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              let chrome = Bundle(url: url)?.executableURL else { throw failure("Chrome and Accessibility access are required") }
        try run(chrome: chrome, basic: true)
        try run(chrome: chrome, basic: false)
    }

    static func main() {
        do { try verify() } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
