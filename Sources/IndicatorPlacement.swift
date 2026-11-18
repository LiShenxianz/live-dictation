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

    private static func parameter(_ field: AXUIElement, _ name: String, _ arg: CFTypeRef) -> CFTypeRef? {
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

    private static func rect(_ value: CFTypeRef?) -> CGRect? {
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

    private static func markerBounds(_ field: AXUIElement) -> CGRect? {
        guard let value = attribute(field, "AXSelectedTextMarkerRange"),
              CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
        let end = AXTextMarkerRangeCopyEndMarker(value as! AXTextMarkerRange)
        let insertion = AXTextMarkerRangeCreate(kCFAllocatorDefault, end, end)
        return rect(parameter(field, "AXBoundsForTextMarkerRange", insertion))
    }

    private static func emptyLine(_ row: CGRect, in field: AXUIElement, at index: Int) -> CGRect? {
        // Chromium exposes an empty paragraph as a whole line, including CSS placeholder text.
        for x in [row.minX + 1, row.maxX - 1] {
            var point = CGPoint(x: x, y: row.midY)
            guard let arg = AXValueCreate(.cgPoint, &point),
                  let hit = range(parameter(field, kAXRangeForPositionParameterizedAttribute, arg)),
                  hit.length == 0, hit.location == index else { return nil }
        }
        return CGRect(x: row.minX, y: row.minY, width: 0, height: row.height)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var p = CGPoint.zero, size = CGSize.zero
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let extent = attribute(element, kAXSizeAttribute), CFGetTypeID(extent) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(extent as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
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
        let marker = markerBounds(field)
        if let marker, marker.width <= 5 { return marker }
        guard let selected = range(attribute(field, kAXSelectedTextRangeAttribute)) else { return nil }
        let index = selected.location + selected.length
        let previous = index > 0 ? textBounds(field, at: index - 1, length: 1) : nil
        if var direct = textBounds(field, at: index, length: 0), direct.width <= 5 {
            // NSTextView sometimes reports the collapsed range exactly one row too high.
            if let previous, abs(previous.maxX - direct.minX) < 4, abs(previous.minY - direct.maxY) < 2 {
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
        if let previous { return CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height) }
        if let layout = RenderedCaret.bounds(in: field, index: index) { return layout }
        if let marker, selected.length == 0 { return emptyLine(marker, in: field, at: index) }
        return nil
    }

    static func origin(for spot: FocusFollowing.Spot?) -> CGPoint? {
        guard let spot else { return nil }
        func documentCaret() -> CGRect? {
            var node = spot.field.flatMap { FocusFollowing.Spot.element($0, kAXParentAttribute) }
            for _ in 0..<32 {
                guard let current = node, current != spot.window else { break }
                if attribute(current, kAXRoleAttribute) as? String == "AXWebArea" {
                    if let bounds = markerBounds(current), bounds.width <= 5 { return bounds }
                    break
                }
                node = FocusFollowing.Spot.element(current, kAXParentAttribute)
            }
            return spot.window.flatMap(markerBounds).flatMap { $0.width <= 5 ? $0 : nil }
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
