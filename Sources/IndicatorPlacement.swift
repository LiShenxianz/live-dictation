import AppKit
import ApplicationServices

enum IndicatorPlacement {
    static let side: CGFloat = 18
    private static let gap: CGFloat = 5

    static func clamp(_ p: CGPoint, to b: CGRect) -> CGPoint {
        CGPoint(x: min(max(b.minX, p.x), b.maxX - side),
                y: min(max(b.minY, p.y), b.maxY - side))
    }

    static func attribute(_ field: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func parameter(_ field: AXUIElement, _ name: String, _ arg: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field, name as CFString, arg, &value) == .success else { return nil }
        return value
    }

    private static func range(_ value: CFTypeRef?) -> CFRange? {
        var result = CFRange()
        guard let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cfRange, &result), result.location >= 0 else { return nil }
        return result
    }

    static func rect(_ value: CFTypeRef?) -> CGRect? {
        var result = CGRect.zero
        guard let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cgRect, &result),
              result.origin.x.isFinite, result.origin.y.isFinite, result.width.isFinite,
              result.width >= 0, result.height > 0, result.height < 150 else { return nil }
        return result
    }

    private static func textBounds(_ field: AXUIElement, at index: Int, length: Int) -> CGRect? {
        var r = CFRange(location: index, length: length)
        guard let arg = AXValueCreate(.cfRange, &r) else { return nil }
        return rect(parameter(field, kAXBoundsForRangeParameterizedAttribute, arg))
    }

    private static func selectedMarkers(in field: AXUIElement) -> AXTextMarkerRange? {
        guard let value = attribute(field, "AXSelectedTextMarkerRange"),
              CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
        return (value as! AXTextMarkerRange)
    }

    private static func markerBounds(in field: AXUIElement, selection: AXTextMarkerRange) -> CGRect? {
        let end = AXTextMarkerRangeCopyEndMarker(selection)
        let insertion = AXTextMarkerRangeCreate(kCFAllocatorDefault, end, end)
        guard let box = rect(parameter(field, "AXBoundsForTextMarkerRange", insertion)) else { return nil }
        if box.width <= 5, let edge = softWrapEnd(in: field, at: end, reported: box) { return edge }
        return box
    }

    /// Chromium can return the next line's origin for both affinities of a soft wrap.
    private static func softWrapEnd(in field: AXUIElement, at end: AXTextMarker, reported: CGRect) -> CGRect? {
        guard let previous = parameter(field, "AXPreviousTextMarkerForTextMarker", end),
              CFGetTypeID(previous) == AXTextMarkerGetTypeID() else { return nil }
        let start = previous as! AXTextMarker
        let character = AXTextMarkerRangeCreate(nil, start, end)
        guard let glyph = rect(parameter(field, "AXBoundsForTextMarkerRange", character)),
              glyph.width > 0, glyph.maxY <= reported.minY + 1,
              let remainder = parameter(field, "AXRightLineTextMarkerRangeForTextMarker", end),
              (parameter(field, "AXLengthForTextMarkerRange", remainder) as? NSNumber)?.intValue == 0,
              let text = parameter(field, "AXStringForTextMarkerRange", character) as? String,
              text.count == 1, text.rangeOfCharacter(from: .newlines) == nil else { return nil }
        let before = AXTextMarkerRangeCreate(nil, start, start)
        guard let leading = rect(parameter(field, "AXBoundsForTextMarkerRange", before)),
              leading.width <= 5, abs(leading.midY - glyph.midY) <= 2 else { return nil }
        let x: CGFloat
        if abs(leading.minX - glyph.minX) <= 1 { x = glyph.maxX }
        else if abs(leading.minX - glyph.maxX) <= 1 { x = glyph.minX }
        else { return nil }
        return CGRect(x: x, y: glyph.minY, width: 0, height: glyph.height)
    }

    private static func emptyLine(_ row: CGRect, in field: AXUIElement, at index: Int, selection: AXTextMarkerRange) -> CGRect? {
        // Chromium exposes an empty paragraph as a whole line, including CSS placeholder text.
        for x in [row.minX + 1, row.maxX - 1] {
            var point = CGPoint(x: x, y: row.midY)
            guard let arg = AXValueCreate(.cgPoint, &point),
                  let hit = range(parameter(field, kAXRangeForPositionParameterizedAttribute, arg)),
                  hit.length == 0, hit.location == index else { return nil }
        }
        let bottom = RenderedCaret.emptyLineBottom(in: field, selection: selection, row: row) ?? row.maxY
        return CGRect(x: row.minX, y: row.minY, width: 0, height: bottom - row.minY)
    }

    static func frame(of element: AXUIElement, allowingZeroWidth: Bool = false) -> CGRect? {
        var p = CGPoint.zero, size = CGSize.zero
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let extent = attribute(element, kAXSizeAttribute), CFGetTypeID(extent) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(extent as! AXValue, .cgSize, &size),
              p.x.isFinite, p.y.isFinite, size.width.isFinite, size.height.isFinite, size.height > 0,
              size.width > 0 || (allowingZeroWidth && size.width == 0) else { return nil }
        return CGRect(origin: p, size: size)
    }

    // Empty Qt text edits can expose the insertion column through hit testing alone.
    private static func emptyInsertion(in field: AXUIElement) -> CGRect? {
        guard let box = frame(of: field), box.width > 12, box.height > 8 else { return nil }
        func hit(_ x: CGFloat, _ y: CGFloat) -> Bool {
            var point = CGPoint(x: x, y: y)
            guard let arg = AXValueCreate(.cgPoint, &point),
                  let result = range(parameter(field, kAXRangeForPositionParameterizedAttribute, arg)) else { return false }
            return result.location == 0 && result.length == 1
        }
        let y = box.minY + 4
        for inset in 0..<9 {
            let x = box.minX + CGFloat(inset)
            guard hit(x, y), !hit(x - 2, y), !hit(x + 2, y) else { continue }
            var low = 4, high = min(Int(box.height), 64)
            guard !hit(x, box.minY + CGFloat(high)) else { continue }
            while high - low > 1 {
                let mid = (low + high) / 2
                if hit(x, box.minY + CGFloat(mid)) { low = mid } else { high = mid }
            }
            return CGRect(x: x, y: y, width: 0, height: CGFloat(high - 4))
        }
        return nil
    }

    private static func caret(in field: AXUIElement) -> CGRect? {
        let markers = selectedMarkers(in: field)
        let marker = markers.flatMap { markerBounds(in: field, selection: $0) }
        if let marker, marker.width <= 5 { return marker }
        guard let selected = range(attribute(field, kAXSelectedTextRangeAttribute)) else { return nil }
        let index = selected.location + selected.length
        func previousGlyph() -> CGRect? {
            index > 0 ? textBounds(field, at: index - 1, length: 1) : nil
        }
        if var direct = textBounds(field, at: index, length: 0), direct.width <= 5 {
            // NSTextView sometimes reports the collapsed range exactly one row too high.
            if let previous = previousGlyph(), abs(previous.maxX - direct.minX) < 4, abs(previous.minY - direct.maxY) < 2 {
                func line(_ i: Int) -> Int? {
                    (parameter(field, kAXLineForIndexParameterizedAttribute, NSNumber(value: i)) as? NSNumber)?.intValue
                }
                if let row = line(index), row == line(index - 1) {
                    direct.origin.y = previous.minY
                    direct.size.height = previous.height
                }
            }
            return direct
        }

        // WeChat returns zero height for a collapsed range but real bounds for individual glyphs.
        let count = (attribute(field, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
        if count.map({ index < $0 || $0 == 0 }) ?? true, let next = textBounds(field, at: index, length: 1) {
            return CGRect(x: next.minX, y: next.minY, width: 0, height: next.height)
        }
        if count == 0, index == 0, marker == nil, let empty = emptyInsertion(in: field) { return empty }
        if let previous = previousGlyph() { return CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height) }
        if let marker, let markers, selected.length == 0 {
            let text = attribute(field, kAXValueAttribute) as? NSString
            let startsLine = index == 0 || (text.map { index <= $0.length && $0.character(at: index - 1) == 10 } ?? false)
            if startsLine, let empty = emptyLine(marker, in: field, at: index, selection: markers) { return empty }
        }
        if let markers, let exact = RenderedCaret.bounds(in: field, selection: markers) { return exact }
        return nil
    }

    static func origin(for spot: FocusFollowing.Spot?) -> CGPoint? {
        guard let spot else { return nil }
        func narrowMarker(in node: AXUIElement) -> CGRect? {
            guard let markers = selectedMarkers(in: node), let box = markerBounds(in: node, selection: markers),
                  box.width <= 5 else { return nil }
            return box
        }
        func documentCaret() -> CGRect? {
            var node = spot.field.flatMap { FocusFollowing.Spot.element($0, kAXParentAttribute) }
            for _ in 0..<32 {
                guard let current = node, current != spot.window else { break }
                if attribute(current, kAXRoleAttribute) as? String == "AXWebArea" {
                    if let bounds = narrowMarker(in: current) { return bounds }
                    break
                }
                node = FocusFollowing.Spot.element(current, kAXParentAttribute)
            }
            return spot.window.flatMap(narrowMarker)
        }
        func editorUnderPointer() -> CGRect? {
            guard spot.opaque, FocusFollowing.Spot.textPointer(), let window = spot.window,
                  let point = CGEvent(source: nil)?.location, frame(of: window)?.contains(point) == true else { return nil }
            let app = AXUIElementCreateApplication(spot.pid)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success else { return nil }
            var candidate: AXUIElement?
            for _ in 0..<32 {
                guard let node = hit else { break }
                if node == window { return candidate.flatMap(caret) }
                let role = attribute(node, kAXRoleAttribute) as? String
                if ["AXTextArea", "AXTextField", "AXComboBox"].contains(role),
                   attribute(node, kAXSubroleAttribute) as? String != "AXSecureTextField" { candidate = node }
                hit = FocusFollowing.Spot.element(node, kAXParentAttribute)
            }
            return nil
        }
        guard let ax = (spot.editable ? spot.field.flatMap(caret) : nil) ?? documentCaret() ?? editorUnderPointer() else { return nil }
        let rect = CGRect(x: ax.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - ax.maxY,
                          width: ax.width, height: ax.height)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect.insetBy(dx: -1, dy: 0)) }) else { return nil }
        return clamp(CGPoint(x: rect.maxX + gap, y: rect.minY - side - 2), to: screen.visibleFrame)
    }
}
