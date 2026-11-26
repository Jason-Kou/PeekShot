import CoreGraphics

/// Pure coordinate math shared by the selection overlay and the editor.
///
/// "View" coordinates are AppKit points with a bottom-left origin on one display.
/// "Global" coordinates are Quartz points with a top-left origin on the primary display.
/// "Pixel" coordinates address the captured image with a top-left origin.
enum Geometry {
    static func rect(from a: CGPoint, to b: CGPoint, square: Bool = false, fromCenter: Bool = false) -> CGRect {
        var dx = b.x - a.x
        var dy = b.y - a.y
        if square {
            let m = max(abs(dx), abs(dy))
            dx = dx < 0 ? -m : m
            dy = dy < 0 ? -m : m
        }
        if fromCenter {
            return CGRect(x: a.x - abs(dx), y: a.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
        }
        return CGRect(x: min(a.x, a.x + dx), y: min(a.y, a.y + dy), width: abs(dx), height: abs(dy))
    }

    static func pixelRect(forViewRect r: CGRect, viewHeight: CGFloat, scale: CGFloat, imageSize: CGSize) -> CGRect {
        let rect = CGRect(x: (r.minX * scale).rounded(),
                          y: ((viewHeight - r.maxY) * scale).rounded(),
                          width: (r.width * scale).rounded(),
                          height: (r.height * scale).rounded())
        return rect.intersection(CGRect(origin: .zero, size: imageSize))
    }

    static func viewRect(forGlobalRect g: CGRect, displayBounds: CGRect) -> CGRect {
        CGRect(x: g.minX - displayBounds.minX,
               y: displayBounds.height - (g.minY - displayBounds.minY) - g.height,
               width: g.width, height: g.height)
    }

    static func globalPoint(forViewPoint p: CGPoint, displayBounds: CGRect) -> CGPoint {
        CGPoint(x: displayBounds.minX + p.x, y: displayBounds.minY + displayBounds.height - p.y)
    }

    /// Snaps the end point so the segment from `a` lies on a multiple of 45 degrees.
    static func snapAngle(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return b }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
