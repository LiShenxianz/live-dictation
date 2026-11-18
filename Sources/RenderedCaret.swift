import ApplicationServices
import Foundation

/// A web editor may anchor a collapsed selection on a paragraph instead of its text leaf.
enum RenderedCaret {
    // An empty paragraph can reserve several rows even when its placeholder paints just one.
    static func emptyLineBottom(in field: AXUIElement, selection: AXTextMarkerRange, row: CGRect) -> CGFloat? {
        let query = IndicatorPlacement.parameter
        let end = AXTextMarkerRangeCopyEndMarker(selection)
        guard let rawOwner = query(field, "AXUIElementForTextMarker", end),
              CFGetTypeID(rawOwner) == AXUIElementGetTypeID() else { return nil }
        let search: [String: Any] = ["AXSearchKey": "AXAnyTypeSearchKey", "AXDirection": "AXDirectionNext", "AXResultsLimit": 8]
        guard let nodes = query(rawOwner as! AXUIElement, "AXUIElementsForSearchPredicate", search as CFDictionary) as? [AXUIElement] else { return nil }

        let area = row.insetBy(dx: -1, dy: -1)
        var hint: CGRect?, hintNode: AXUIElement?, lineBreak: CGRect?
        for node in nodes {
            let frame = IndicatorPlacement.frame(of: node, allowingZeroWidth: true)
            if let frame, frame.width > 0 {
                if area.contains(frame), IndicatorPlacement.attribute(node, kAXRoleAttribute) as? String == "AXStaticText" {
                    if hintNode == nil { hintNode = node }
                    hint = hint.map { $0.union(frame) } ?? frame
                }
            } else if let rawRun = query(field, "AXTextMarkerRangeForUIElement", node),
                      CFGetTypeID(rawRun) == AXTextMarkerRangeGetTypeID(),
                      query(field, "AXStringForTextMarkerRange", rawRun) as? String == "\n" {
                let start = AXTextMarkerRangeCopyStartMarker(rawRun as! AXTextMarkerRange)
                guard let span = query(field, "AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray),
                      query(field, "AXStringForTextMarkerRange", span) as? String == "" else { continue }
                let measured = IndicatorPlacement.rect(query(field, "AXBoundsForTextMarkerRange", rawRun))
                lineBreak = measured.flatMap { $0.width <= 2 ? $0 : nil } ?? frame
            }
        }

        if let hint, let hintNode {
            var lineHeight = lineBreak?.height
            if lineHeight == nil, let range = query(field, "AXTextMarkerRangeForUIElement", hintNode),
               CFGetTypeID(range) == AXTextMarkerRangeGetTypeID() {
                let start = AXTextMarkerRangeCopyStartMarker(range as! AXTextMarkerRange)
                let point = AXTextMarkerRangeCreate(nil, start, start)
                if let glyph = IndicatorPlacement.rect(query(field, "AXBoundsForTextMarkerRange", point)), glyph.width <= 2 {
                    lineHeight = glyph.height
                }
            }
            if let lineHeight, hint.height > lineHeight + 1 { return nil }
            return hint.maxY
        }
        guard let lineBreak, lineBreak.minY >= area.minY, lineBreak.maxY <= area.maxY else { return nil }
        return lineBreak.maxY
    }

    static func bounds(in field: AXUIElement, selection: AXTextMarkerRange) -> CGRect? {
        func query(_ key: String, _ input: CFTypeRef) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(field, key as CFString, input, &value) == .success else { return nil }
            return value
        }

        let end = AXTextMarkerRangeCopyEndMarker(selection)
        guard let node = query("AXUIElementForTextMarker", end), CFGetTypeID(node) == AXUIElementGetTypeID(),
              let fieldBox = IndicatorPlacement.frame(of: field) else { return nil }
        var remaining = 256
        func matchingEdge(in node: AXUIElement) -> CGRect? {
            guard remaining > 0 else { return nil }
            remaining -= 1
            if IndicatorPlacement.attribute(node, kAXRoleAttribute) as? String == "AXStaticText" {
                guard let raw = query("AXTextMarkerRangeForUIElement", node),
                      CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() else { return nil }
                let run = raw as! AXTextMarkerRange
                for marker in [AXTextMarkerRangeCopyEndMarker(run), AXTextMarkerRangeCopyStartMarker(run)] {
                    guard let span = query("AXTextMarkerRangeForUnorderedTextMarkers", [marker, end] as CFArray),
                          query("AXStringForTextMarkerRange", span) as? String == "" else { continue }
                    let collapsed = AXTextMarkerRangeCreate(nil, marker, marker)
                    if let box = IndicatorPlacement.rect(query("AXBoundsForTextMarkerRange", collapsed)),
                       box.width <= 2, fieldBox.insetBy(dx: -2, dy: -2).contains(CGPoint(x: box.midX, y: box.midY)) {
                        return box
                    }
                }
            } else if let children = IndicatorPlacement.attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children.reversed() where remaining > 0 {
                    if let edge = matchingEdge(in: child) { return edge }
                }
            }
            return nil
        }
        return matchingEdge(in: node as! AXUIElement)
    }
}
