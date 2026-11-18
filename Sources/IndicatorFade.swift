import AppKit

/// Changes only the indicator's opacity. A reversal starts at the current opacity.
final class IndicatorFade {
    private let panel: NSPanel
    private var destination: CGPoint?
    private var visible = false
    private var clock: Timer?

    init(panel: NSPanel) {
        self.panel = panel
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
    }

    func display(at origin: CGPoint, immediately: Bool) {
        let point = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
        if !immediately && panel.isVisible && panel.alphaValue > 0 && point != panel.frame.origin {
            destination = point
            animate(false)
            return
        }
        destination = nil
        if panel.frame.origin != point { panel.setFrameOrigin(point) }
        animate(true, immediately: immediately)
    }

    func hide() {
        destination = nil
        animate(false)
    }

    private func animate(_ show: Bool, immediately: Bool = false) {
        if show && immediately {
            clock?.invalidate()
            clock = nil
            visible = true
            panel.ignoresMouseEvents = false
            panel.alphaValue = 1
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }
        guard visible != show else { return }
        visible = show
        clock?.invalidate()
        panel.ignoresMouseEvents = !show
        if show && !panel.isVisible { panel.orderFrontRegardless() }

        let start = panel.alphaValue
        let end: CGFloat = show ? 1 : 0
        let began = ProcessInfo.processInfo.systemUptime
        let seconds = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : (show ? 0.22 : (destination == nil ? 0.24 : 0.15))
        let duration = max(0.04, seconds * Double(abs(end - start)))
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = CGFloat(min(1, (ProcessInfo.processInfo.systemUptime - began) / duration))
            let eased = t * t * (3 - 2 * t)
            self.panel.alphaValue = start + (end - start) * eased
            if t == 1 {
                timer.invalidate()
                self.clock = nil
                if !show {
                    if let point = self.destination {
                        self.destination = nil
                        self.panel.setFrameOrigin(point)
                        self.animate(true)
                    } else { self.panel.orderOut(nil) }
                }
            }
        }
        clock = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit { clock?.invalidate() }
}
