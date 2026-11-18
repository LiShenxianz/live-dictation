import AppKit
import CoreText

/// Some web editors expose the rendered text runs and selection, but return zero-sized glyph bounds.
enum RenderedCaret {
    private struct Run {
        let text: String
        let ink: CGRect
        let paragraph: CGRect
    }

    static func bounds(in field: AXUIElement, index: Int) -> CGRect? {
        let attr = IndicatorPlacement.attribute
        guard let box = IndicatorPlacement.frame(of: field),
              let value = attr(field, kAXValueAttribute) as? String, value.utf16.count <= 16384 else { return nil }
        let content = value as NSString
        guard index >= 0, index <= content.length else { return nil }
        var runs: [Run] = []
        var remaining = 256
        func collect(_ node: AXUIElement, parent: CGRect) {
            remaining -= 1
            guard remaining >= 0 else { return }
            let frame = IndicatorPlacement.frame(of: node) ?? parent
            if attr(node, kAXRoleAttribute) as? String == "AXStaticText" {
                if let text = attr(node, kAXValueAttribute) as? String, !text.isEmpty,
                   box.insetBy(dx: -2, dy: -2).intersects(frame) {
                    runs.append(Run(text: text, ink: frame, paragraph: parent))
                }
            } else if let children = attr(node, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children where remaining > 0 { collect(child, parent: frame) }
            }
        }
        collect(field, parent: box)
        if let marker = attr(field, "AXSelectedTextMarkerRange"), CFGetTypeID(marker) == AXTextMarkerRangeGetTypeID() {
            let end = AXTextMarkerRangeCopyEndMarker(marker as! AXTextMarkerRange)
            if let edge = lineEnd(in: field, at: end, inside: box) { return edge }
        }
        var offset = 0
        for run in runs {
            let match = content.range(of: run.text, options: .literal, range: NSRange(location: offset, length: content.length - offset))
            guard match.location != NSNotFound else { continue }
            if (match.location...NSMaxRange(match)).contains(index) {
                return caret(in: run, at: index - match.location)
            }
            offset = NSMaxRange(match)
        }
        return nil
    }

    private static func lineEnd(in field: AXUIElement, at marker: AXTextMarker, inside fieldBox: CGRect) -> CGRect? {
        func query(_ key: String, _ input: CFTypeRef) -> CFTypeRef? {
            var out: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(field, key as CFString, input, &out) == .success else { return nil }
            return out
        }
        guard let leaf = query("AXUIElementForTextMarker", marker),
              CFGetTypeID(leaf) == AXUIElementGetTypeID(),
              IndicatorPlacement.attribute(leaf as! AXUIElement, kAXRoleAttribute) as? String == "AXStaticText",
              let row = query("AXLineTextMarkerRangeForTextMarker", marker), CFGetTypeID(row) == AXTextMarkerRangeGetTypeID()
        else { return nil }
        let start = AXTextMarkerRangeCopyStartMarker(row as! AXTextMarkerRange)
        let prefix = AXTextMarkerRangeCreate(nil, start, marker)
        guard let raw = query("AXBoundsForTextMarkerRange", prefix), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(raw as! AXValue, .cgRect, &bounds), bounds.height > 0, bounds.height < 100,
              fieldBox.insetBy(dx: -2, dy: -2).contains(bounds) else { return nil }
        return CGRect(x: bounds.maxX, y: bounds.minY, width: 0, height: bounds.height)
    }

    private static func caret(in run: Run, at offset: Int) -> CGRect? {
        let box = run.ink
        let paragraph = run.paragraph
        guard box.width > 0, paragraph.width > 0 else { return nil }
        // Web line boxes often include equal leading above and below the first/last glyphs.
        let leading = max(0, box.minY - paragraph.minY)
        let defaultSize = NSFont.systemFontSize
        let nominalHeight = defaultSize * 1.25 + leading * 2
        let count = max(1, Int((paragraph.height / nominalHeight).rounded()))
        let lineHeight = paragraph.height / CGFloat(count)
        guard lineHeight >= 8, lineHeight < 100 else { return nil }
        let em = max(7, (lineHeight - 2 * leading) * 0.875)
        let font = NSFont.systemFont(ofSize: em)
        let string = NSAttributedString(string: run.text, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        var start = 0
        for row in 0..<count where start < string.length {
            let length = row == count - 1 ? string.length - start :
                CTTypesetterSuggestLineBreak(typesetter, start, Double(paragraph.width))
            guard length > 0 else { return nil }
            let end = start + length
            if offset < end || end == string.length && offset == end {
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length))
                let advance = CGFloat(CTLineGetOffsetForStringIndex(line, offset, nil))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let x = count == 1 && width > 0 ? box.minX + advance * box.width / width : paragraph.minX + advance
                return CGRect(x: min(max(x, paragraph.minX), paragraph.maxX),
                              y: paragraph.minY + CGFloat(row) * lineHeight, width: 0, height: lineHeight)
            }
            start = end
        }
        return nil
    }
}
