import AppKit

private final class LightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DragSurface: NSView {
    var pressed: ((NSEvent) -> Void)?
    var moved: (() -> Void)?
    var released: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed?(event) }
    override func mouseDragged(with event: NSEvent) { moved?() }
    override func mouseUp(with event: NSEvent) { released?() }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
}

final class MicrophoneLight {
    private let side = IndicatorPlacement.side
    private let panel: NSPanel
    private let dot = NSView(frame:NSRect(x:5,y:5,width:8,height:8))
    private var drag: (mouse: NSPoint, origin: NSPoint)?
    private let fade: IndicatorFade
    private var pendingHide: DispatchWorkItem?
    private var pendingReveal: DispatchWorkItem?
    private var firstHideTime = DispatchTime.now()
    private var speaking = false
    private(set) var listening = false
    private var dragged = false
    private let positionKey = "microphoneLightPinnedOrigin"
    private var lastCaret: (spot: FocusFollowing.Spot, origin: CGPoint)?
    private var pinned: NSPoint?

    init() {
        panel = LightPanel(contentRect:NSRect(x:0,y:0,width:side,height:side),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        fade = IndicatorFade(panel: panel)
        panel.title = "听写麦克风"
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.transient]
        if let saved = UserDefaults.standard.string(forKey:positionKey) { pinned = NSPointFromString(saved) }
        let ring = DragSurface(frame:NSRect(origin:.zero,size:panel.frame.size))
        ring.toolTip = "拖动固定位置，双击恢复跟随光标"
        ring.wantsLayer = true
        ring.layer?.backgroundColor = NSColor(white:0.12,alpha:0.88).cgColor
        ring.layer?.cornerRadius = side/2
        ring.layer?.borderWidth = 1
        ring.layer?.borderColor = NSColor(white:1,alpha:0.45).cgColor
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        dot.layer?.cornerRadius = 4
        ring.addSubview(dot)
        panel.contentView = ring
        ring.pressed = { [weak self] event in
            guard let self else { return }
            if event.clickCount == 2 {
                self.drag = nil
                self.pinned = nil
                UserDefaults.standard.removeObject(forKey:self.positionKey)
                self.reposition(FocusFollowing.Spot.current())
            } else {
                self.dragged = false
                self.drag = (NSEvent.mouseLocation,self.panel.frame.origin)
            }
        }
        ring.moved = { [weak self] in
            guard let self, let drag = self.drag else { return }
            let mouse = NSEvent.mouseLocation
            guard hypot(mouse.x-drag.mouse.x,mouse.y-drag.mouse.y) > 2,
                  let screen = NSScreen.screens.first(where:{$0.frame.contains(mouse)}) else { return }
            self.dragged = true
            let point = NSPoint(x:drag.origin.x+mouse.x-drag.mouse.x,y:drag.origin.y+mouse.y-drag.mouse.y)
            self.panel.setFrameOrigin(IndicatorPlacement.clamp(point,to:screen.visibleFrame))
        }
        ring.released = { [weak self] in
            guard let self, self.drag != nil else { return }
            if self.dragged {
                self.pinned = self.panel.frame.origin
                UserDefaults.standard.set(NSStringFromPoint(self.panel.frame.origin),forKey:self.positionKey)
            }
            self.drag = nil
            self.reposition(FocusFollowing.Spot.current())
        }
    }

    private func reposition(_ spot: FocusFollowing.Spot?, immediately: Bool = false) {
        guard drag == nil else { return }
        guard listening && !speaking else { fade.hide(); return }
        let origin: NSPoint?
        if let pinned, let screen = NSScreen.screens.first(where:{$0.frame.contains(pinned)}) {
            origin = IndicatorPlacement.clamp(pinned,to:screen.visibleFrame)
        } else if let spot, let point = IndicatorPlacement.origin(for: spot) {
            lastCaret = (spot, point)
            origin = point
        } else if let lastCaret, let spot, spot.field != nil, spot == lastCaret.spot,
                  NSScreen.screens.contains(where: { $0.visibleFrame.contains(lastCaret.origin) }) {
            origin = lastCaret.origin
        } else {
            lastCaret = nil
            origin = nil
        }
        guard let origin else {
            fade.hide()
            return
        }
        fade.display(at: origin, immediately: immediately)
    }
    func follow(_ spot: FocusFollowing.Spot?) { if listening { reposition(spot) } }
    func show(at spot: FocusFollowing.Spot? = FocusFollowing.Spot.current(), immediately: Bool = true) {
        cancelSpeechTimers()
        speaking = false
        listening = true
        firstHideTime = .now() + 0.9
        reposition(spot, immediately: immediately)
    }

    func inputAdvanced(typing: Bool = false) {
        guard listening else { return }
        if typing {
            pendingHide?.cancel()
            pendingHide = nil
            speaking = true
            if drag == nil { fade.hide() }
        } else if !speaking && pendingHide == nil {
            // Leave the opening cue visible even if recognition delivers text immediately.
            let hide = DispatchWorkItem { [weak self] in
                guard let self, self.listening else { return }
                self.pendingHide = nil
                self.speaking = true
                if self.drag == nil { self.fade.hide() }
            }
            pendingHide = hide
            DispatchQueue.main.asyncAfter(deadline: firstHideTime, execute: hide)
        }
        pendingReveal?.cancel()
        let reveal = DispatchWorkItem { [weak self] in
            guard let self, self.listening else { return }
            self.pendingReveal = nil
            self.pendingHide?.cancel()
            self.pendingHide = nil
            self.speaking = false
            self.reposition(FocusFollowing.Spot.current())
        }
        pendingReveal = reveal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: reveal)
    }

    private func cancelSpeechTimers() {
        pendingHide?.cancel()
        pendingHide = nil
        pendingReveal?.cancel()
        pendingReveal = nil
    }

    func hide() {
        cancelSpeechTimers()
        listening = false
        lastCaret = nil
        speaking = false
        drag = nil
        fade.hide()
    }
}
