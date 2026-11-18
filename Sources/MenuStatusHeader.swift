import AppKit

final class MenuStatusHeader: NSView {
    private let status = NSTextField(labelWithString: "")

    init(title: String, icon: NSImage) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 38))
        let image = NSImageView(image: icon)
        image.frame = NSRect(x: 15, y: 6, width: 26, height: 26)
        addSubview(image)

        let name = NSTextField(labelWithString: title)
        name.font = .menuFont(ofSize: 13)
        status.font = .systemFont(ofSize: 12)
        for (label, y) in [(name, 19), (status, 3)] {
            label.frame = NSRect(x: 48, y: y, width: 164, height: 16)
            label.autoresizingMask = [.width]
            label.lineBreakMode = .byTruncatingTail
            label.textColor = .labelColor
            addSubview(label)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    func update(_ text: String) {
        let line = NSMutableAttributedString()
        if text == "就绪" {
            line.append(NSAttributedString(string: "●  ", attributes: [.foregroundColor: NSColor.systemGreen]))
        }
        line.append(NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.labelColor]))
        status.attributedStringValue = line
        setAccessibilityValue(text)
    }
}
