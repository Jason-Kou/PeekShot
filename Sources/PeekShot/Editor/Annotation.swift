import AppKit

enum AnnotationKind: Equatable {
    case arrow, line, rectangle, ellipse, pencil, highlighter, text, counter, pixelate, blur, spotlight
}

enum ToolKind: String, CaseIterable, Identifiable {
    case select, crop, arrow, line, rectangle, ellipse, pencil, highlighter, text, counter, pixelate, blur, spotlight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .crop: return "Crop"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .pencil: return "Pencil"
        case .highlighter: return "Highlighter"
        case .text: return "Text"
        case .counter: return "Counter"
        case .pixelate: return "Pixelate"
        case .blur: return "Blur"
        case .spotlight: return "Spotlight"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .crop: return "crop"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pencil: return "scribble"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .pixelate: return "square.grid.3x3.fill"
        case .blur: return "drop"
        case .spotlight: return "rectangle.dashed"
        }
    }

    /// Single key that selects the tool while the canvas has focus.
    var shortcut: Character {
        switch self {
        case .select: return "v"
        case .crop: return "c"
        case .arrow: return "a"
        case .line: return "l"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .pencil: return "p"
        case .highlighter: return "h"
        case .text: return "t"
        case .counter: return "n"
        case .pixelate: return "x"
        case .blur: return "b"
        case .spotlight: return "s"
        }
    }

    var annotationKind: AnnotationKind? {
        switch self {
        case .select, .crop: return nil
        case .arrow: return .arrow
        case .line: return .line
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .pencil: return .pencil
        case .highlighter: return .highlighter
        case .text: return .text
        case .counter: return .counter
        case .pixelate: return .pixelate
        case .blur: return .blur
        case .spotlight: return .spotlight
        }
    }
}

/// One drawn object. All coordinates are image points with a top-left origin.
struct Annotation: Identifiable, Equatable {
    let id: UUID
    var kind: AnnotationKind
    /// Corner points for box shapes, end points for lines, anchor for text and counters.
    var start: CGPoint
    var end: CGPoint
    /// Freehand path for pencil and highlighter.
    var points: [CGPoint] = []
    var text = ""
    var color: NSColor
    /// One slider value (1...12) drives stroke width, font size, counter size and effect strength.
    var size: CGFloat
    var filled = false
    var number = 0

    init(kind: AnnotationKind, at point: CGPoint, color: NSColor, size: CGFloat, filled: Bool = false) {
        id = UUID()
        self.kind = kind
        start = point
        end = point
        self.color = color
        self.size = size
        self.filled = filled
    }

    var strokeWidth: CGFloat { kind == .highlighter ? size * 3 + 8 : size }
    var fontSize: CGFloat { 10 + size * 3.5 }
    var font: NSFont { .systemFont(ofSize: fontSize, weight: .bold) }
    var counterRadius: CGFloat { 9 + size * 1.5 }

    var isBox: Bool { [.rectangle, .ellipse, .pixelate, .blur, .spotlight].contains(kind) }
    var isSegment: Bool { kind == .arrow || kind == .line }
    var isFreehand: Bool { kind == .pencil || kind == .highlighter }

    var rect: CGRect { Geometry.rect(from: start, to: end) }

    var attributedText: NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
    }

    var bounds: CGRect {
        switch kind {
        case .text:
            return CGRect(origin: start, size: attributedText.size())
        case .counter:
            let r = counterRadius
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        case .pencil, .highlighter:
            guard let first = points.first else { return .zero }
            let box = points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
            return box.insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2)
        default:
            return rect
        }
    }

    /// Whether the object is big enough to keep after the mouse is released.
    var isSubstantial: Bool {
        if isFreehand { return points.count > 1 }
        if isSegment { return hypot(end.x - start.x, end.y - start.y) > 3 }
        if isBox { return rect.width > 3 && rect.height > 3 }
        return true
    }

    func hitTest(_ p: CGPoint) -> Bool {
        let tolerance = max(6, strokeWidth / 2 + 3)
        switch kind {
        case .arrow, .line:
            return Geometry.distance(from: p, toSegment: start, end) <= tolerance
        case .pencil, .highlighter:
            guard points.count > 1 else { return false }
            return zip(points, points.dropFirst()).contains {
                Geometry.distance(from: p, toSegment: $0, $1) <= tolerance
            }
        case .rectangle where !filled, .ellipse where !filled:
            // Outlined shapes only react near their border so objects inside stay reachable.
            let outer = rect.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = rect.insetBy(dx: tolerance, dy: tolerance)
            return outer.contains(p) && (inner.isNull || inner.isEmpty || !inner.contains(p))
        case .counter:
            return hypot(p.x - start.x, p.y - start.y) <= counterRadius + 3
        default:
            return bounds.insetBy(dx: -3, dy: -3).contains(p)
        }
    }

    mutating func translate(dx: CGFloat, dy: CGFloat) {
        start.x += dx
        start.y += dy
        end.x += dx
        end.y += dy
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// Resize handle positions: the two ends of a segment or the four corners of a box.
    var handles: [CGPoint] {
        if isSegment { return [start, end] }
        if isBox {
            let r = rect
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        }
        return []
    }
}
