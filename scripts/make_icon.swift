// Generates the app icon set. Usage: swift scripts/make_icon.swift Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Rounded tile with the standard macOS icon margins.
    let tile = CGRect(x: size * 0.1, y: size * 0.1, width: size * 0.8, height: size * 0.8)
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: size * 0.18, cornerHeight: size * 0.18, transform: nil))
    ctx.clip()
    let colors = [CGColor(srgbRed: 0.16, green: 0.73, blue: 0.62, alpha: 1),
                  CGColor(srgbRed: 0.10, green: 0.36, blue: 0.80, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY),
                           end: CGPoint(x: tile.maxX, y: tile.minY), options: [])

    // Four viewfinder corners around a selection dot.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(size * 0.055)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let frame = tile.insetBy(dx: size * 0.17, dy: size * 0.17)
    let arm = size * 0.13
    for (corner, dx, dy) in [(CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0),
                             (CGPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0),
                             (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0),
                             (CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0)] {
        ctx.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
        ctx.addLine(to: corner)
        ctx.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
        ctx.strokePath()
    }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    let dot = size * 0.07
    ctx.fillEllipse(in: CGRect(x: tile.midX - dot, y: tile.midY - dot, width: dot * 2, height: dot * 2))

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
