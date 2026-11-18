import AppKit

/// Start and stop sounds belong to a user-initiated dictation session, across focus changes.
final class RecordingCues {
    private let startTone = tone("dt-begin", fallback: "Tink")
    private let stopTone = tone("dt-confirm", fallback: "Pop")

    private static func tone(_ file: String, fallback: String) -> NSSound? {
        let systemSounds = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/AssistantServices.framework/Resources")
        return NSSound(contentsOf: systemSounds.appendingPathComponent(file + ".caf"), byReference: false)
            ?? NSSound(named: NSSound.Name(fallback))
    }

    private var started = false

    private var lastTarget: FocusFollowing.Spot?

    func begin() {
        let target = FocusFollowing.Spot.current()
        guard !started || target != lastTarget else { return }
        lastTarget = target
        started = true
        stopTone?.stop()
        startTone?.stop()
        startTone?.play()
    }

    func end() {
        guard started else { return }
        started = false
        lastTarget = nil
        startTone?.stop()
        stopTone?.play()
    }
}
