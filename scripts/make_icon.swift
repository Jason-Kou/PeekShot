// Generates the app icon set. Usage: swift scripts/make_icon.swift Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// Strokes an L shape with a rounded elbow at `corner`; `dx`/`dy` point along its two arms.
func bracket(_ ctx: CGContext, corner: CGPoint, dx: CGFloat, dy: CGFloat, arm: CGFloat, radius: CGFloat) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
    path.addArc(tangent1End: corner, tangent2End: CGPoint(x: corner.x, y: corner.y + arm * dy), radius: radius)
    path.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
    ctx.addPath(path)
    ctx.strokePath()
}

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Blue tile with the standard macOS icon margins.
    let tile = CGRect(x: size * 0.1, y: size * 0.1, width: size * 0.8, height: size * 0.8)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: size * 0.18, cornerHeight: size * 0.18, transform: nil))
    ctx.clip()
    let colors = [CGColor(srgbRed: 0.20, green: 0.56, blue: 1.00, alpha: 1),
                  CGColor(srgbRed: 0.05, green: 0.33, blue: 0.86, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: sRGB, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.midX, y: tile.maxY),
                           end: CGPoint(x: tile.midX, y: tile.minY), options: [])
    ctx.restoreGState()

    // Two opposite corner brackets: a selection being dragged out.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(size * 0.07)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let frame = tile.insetBy(dx: size * 0.2, dy: size * 0.2)
    bracket(ctx, corner: CGPoint(x: frame.minX, y: frame.maxY), dx: 1, dy: -1, arm: size * 0.2, radius: size * 0.06)
    bracket(ctx, corner: CGPoint(x: frame.maxX, y: frame.minY), dx: -1, dy: 1, arm: size * 0.2, radius: size * 0.06)

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(output.path)")
