import AppKit
import CoreImage

/// Draws the base image and annotations into a context whose coordinate space is image points
/// with a top-left origin (a flipped view, or a bitmap context flipped by `flatten`).
final class AnnotationRenderer {
    private let ciContext = CIContext()
    private var effectCache: [UUID: (key: String, image: CGImage)] = [:]
    private var cachedBase: CGImage?

    func draw(_ annotations: [Annotation], base: CGImage, scale: CGFloat, in ctx: CGContext) {
        if cachedBase !== base {
            cachedBase = base
            effectCache.removeAll()
        }
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(base.width) / scale, height: CGFloat(base.height) / scale)
        Self.drawImage(base, in: canvas, ctx)

        for annotation in annotations where annotation.kind == .pixelate || annotation.kind == .blur {
            drawEffect(annotation, base: base, scale: scale, in: ctx)
        }

        let spotlights = annotations.filter { $0.kind == .spotlight }
        if !spotlights.isEmpty {
            let path = CGMutablePath()
            path.addRect(canvas)
            spotlights.forEach { path.addRect($0.rect.intersection(canvas)) }
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            ctx.fillPath(using: .evenOdd)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for annotation in annotations {
            drawShape(annotation, in: ctx)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Renders everything into a new image with the pixel size of `base`.
    func flatten(_ annotations: [Annotation], base: CGImage, scale: CGFloat) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(base.height))
        ctx.scaleBy(x: scale, y: -scale)
        draw(annotations, base: base, scale: scale, in: ctx)
        return ctx.makeImage()
    }

    /// Draws a CGImage upright in a top-left-origin context.
    static func drawImage(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    // MARK: Effects

    private func drawEffect(_ annotation: Annotation, base: CGImage, scale: CGFloat, in ctx: CGContext) {
        let pixelRect = CGRect(x: annotation.rect.minX * scale, y: annotation.rect.minY * scale,
                               width: annotation.rect.width * scale, height: annotation.rect.height * scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard pixelRect.width >= 2, pixelRect.height >= 2 else { return }

        let key = "\(annotation.kind)|\(pixelRect)|\(annotation.size)"
        let image: CGImage
        if let cached = effectCache[annotation.id], cached.key == key {
            image = cached.image
        } else {
            guard let source = base.cropping(to: pixelRect) else { return }
            let rendered: CGImage?
            if annotation.kind == .pixelate {
                rendered = Self.mosaic(source, blockSize: max(4, (4 + annotation.size * 2) * scale))
            } else {
                let input = CIImage(cgImage: source)
                let output = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: (3 + annotation.size * 1.5) * scale,
                ])
                rendered = ciContext.createCGImage(output, from: input.extent)
            }
            guard let rendered else { return }
            effectCache[annotation.id] = (key, rendered)
            image = rendered
        }
        let target = CGRect(x: pixelRect.minX / scale, y: pixelRect.minY / scale,
                            width: pixelRect.width / scale, height: pixelRect.height / scale)
        Self.drawImage(image, in: target, ctx)
    }

    /// Averages the image down to one pixel per block, then scales it back up without smoothing.
    static func mosaic(_ image: CGImage, blockSize: CGFloat) -> CGImage? {
        let columns = max(1, Int((CGFloat(image.width) / blockSize).rounded(.up)))
        let rows = max(1, Int((CGFloat(image.height) / blockSize).rounded(.up)))
        func context(_ width: Int, _ height: Int) -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let small = context(columns, rows) else { return nil }
        small.interpolationQuality = .high
        small.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        guard let averaged = small.makeImage(), let large = context(image.width, image.height) else { return nil }
        large.interpolationQuality = .none
        large.draw(averaged, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return large.makeImage()
    }

    // MARK: Shapes

    private func drawShape(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.strokeWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch a.kind {
        case .pixelate, .blur, .spotlight:
            break
        case .line:
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.strokePath()
        case .arrow:
            drawArrow(a, in: ctx)
        case .rectangle:
            let path = CGPath(roundedRect: a.rect, cornerWidth: min(3, a.rect.width / 2),
                              cornerHeight: min(3, a.rect.height / 2), transform: nil)
            ctx.addPath(path)
            a.filled ? ctx.fillPath() : ctx.strokePath()
        case .ellipse:
            ctx.addEllipse(in: a.rect)
            a.filled ? ctx.fillPath() : ctx.strokePath()
        case .pencil, .highlighter:
            guard let first = a.points.first else { return }
            if a.kind == .highlighter {
                ctx.setBlendMode(.multiply)
                ctx.setStrokeColor(a.color.withAlphaComponent(0.45).cgColor)
                ctx.setLineCap(.butt)
            }
            ctx.move(to: first)
            a.points.dropFirst().forEach { ctx.addLine(to: $0) }
            ctx.strokePath()
        case .text:
            a.attributedText.draw(at: a.start)
        case .counter:
            let bounds = a.bounds
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: 0.35))
            ctx.fillEllipse(in: bounds)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            let label = NSAttributedString(string: "\(a.number)", attributes: [
                .font: NSFont.systemFont(ofSize: a.counterRadius * 1.1, weight: .bold),
                .foregroundColor: a.color.isLight ? NSColor.black : NSColor.white,
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        }
    }

    private func drawArrow(_ a: Annotation, in ctx: CGContext) {
        let dx = a.end.x - a.start.x, dy = a.end.y - a.start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let ux = dx / length, uy = dy / length
        let headLength = min(length * 0.6, 10 + a.strokeWidth * 3)
        let headHalfWidth = headLength * 0.45
        let base = CGPoint(x: a.end.x - ux * headLength, y: a.end.y - uy * headLength)

        ctx.move(to: a.start)
        ctx.addLine(to: CGPoint(x: a.end.x - ux * headLength * 0.8, y: a.end.y - uy * headLength * 0.8))
        ctx.strokePath()

        ctx.move(to: a.end)
        ctx.addLine(to: CGPoint(x: base.x - uy * headHalfWidth, y: base.y + ux * headHalfWidth))
        ctx.addLine(to: CGPoint(x: base.x + uy * headHalfWidth, y: base.y - ux * headHalfWidth))
        ctx.closePath()
        ctx.fillPath()
    }
}

extension NSColor {
    /// True for colors that need dark text on top.
    var isLight: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent > 0.7
    }
}
