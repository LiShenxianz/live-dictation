import AppKit

/// A recording light near the pointer. It never accepts focus or mouse events.
final class MicrophoneLight {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 28, height: 28),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let dot = NSView(frame: NSRect(x: 8, y: 8, width: 12, height: 12))

    init() {
        panel.title = "听写麦克风"
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let ring = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        ring.wantsLayer = true
        ring.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.91).cgColor
        ring.layer?.cornerRadius = 14
        ring.layer?.borderWidth = 1
        ring.layer?.borderColor = NSColor(white: 1, alpha: 0.4).cgColor
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        ring.addSubview(dot)
        panel.contentView = ring
    }

    private func indicatorPoint() -> NSPoint {
        let pointer = NSEvent.mouseLocation
        guard let spot = FocusFollowing.Spot.current(), let main = NSScreen.screens.first else { return pointer }
        if let field = spot.field {
            var range: CFTypeRef?, bounds: CFTypeRef?
            if AXUIElementCopyAttributeValue(field,kAXSelectedTextRangeAttribute as CFString,&range) == .success,
               let range, AXUIElementCopyParameterizedAttributeValue(field,kAXBoundsForRangeParameterizedAttribute as CFString,range,&bounds) == .success,
               let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() {
                var caret = CGRect.zero
                if AXValueGetValue(bounds as! AXValue,.cgRect,&caret), caret.height > 0, caret.height < 150 {
                    return NSPoint(x:caret.maxX,y:main.frame.maxY-caret.maxY)
                }
            }
        }
        guard let window=spot.window else { return pointer }
        var origin: CFTypeRef?, size: CFTypeRef?, point=CGPoint.zero, extent=CGSize.zero
        guard AXUIElementCopyAttributeValue(window,kAXPositionAttribute as CFString,&origin) == .success,
              AXUIElementCopyAttributeValue(window,kAXSizeAttribute as CFString,&size) == .success,
              let origin, let size, CFGetTypeID(origin)==AXValueGetTypeID(), CFGetTypeID(size)==AXValueGetTypeID(),
              AXValueGetValue(origin as! AXValue,.cgPoint,&point), AXValueGetValue(size as! AXValue,.cgSize,&extent)
        else { return pointer }
        let frame=CGRect(x:point.x,y:main.frame.maxY-point.y-extent.height,width:extent.width,height:extent.height)
        return frame.contains(pointer) ? pointer : NSPoint(x:frame.midX,y:frame.minY+55)
    }

    func show() {
        let point = indicatorPoint()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        let b = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: min(max(b.minX, point.x + 12), b.maxX - size.width),
            y: max(b.minY, min(point.y - size.height - 8, b.maxY - size.height))))
        signal(false)
        panel.orderFrontRegardless()
    }

    func signal(_ audible: Bool) {
        dot.layer?.backgroundColor = (audible ? NSColor.systemGreen : NSColor(white: 0.82, alpha: 1)).cgColor
    }

    func hide() { panel.orderOut(nil) }
}
