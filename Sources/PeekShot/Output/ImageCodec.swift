import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One screenshot moving through the app. `fileURL` points into the history folder when it is stored there.
final class CaptureItem {
    var image: CGImage
    let scale: CGFloat
    var fileURL: URL?

    init(image: CGImage, scale: CGFloat, fileURL: URL? = nil) {
        self.image = image
        self.scale = scale
        self.fileURL = fileURL
    }

    var pointSize: CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    var nsImage: NSImage { NSImage(cgImage: image, size: pointSize) }
}

enum ImageCodec {
    static func data(for image: CGImage, scale: CGFloat, format: ImageFormat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil)
        else { return nil }
        // Record the density so Retina captures open at their on-screen size.
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        if format == .jpg { properties[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    @discardableResult
    static func write(_ image: CGImage, scale: CGFloat, format: ImageFormat, to url: URL) -> Bool {
        guard let data = data(for: image, scale: scale, format: format) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func load(_ url: URL) -> CaptureItem? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let scale = max(1, (dpi / 72).rounded())
        return CaptureItem(image: image, scale: scale, fileURL: url)
    }

    static func thumbnail(for url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func copyToPasteboard(_ item: CaptureItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let png = data(for: item.image, scale: item.scale, format: .png) {
            pasteboard.setData(png, forType: .png)
        }
        if let tiff = item.nsImage.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    static func imageFromPasteboard() -> CGImage? {
        guard let image = NSImage(pasteboard: NSPasteboard.general) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func fileName(for date: Date, format: ImageFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "PeekShot \(formatter.string(from: date)).\(format.rawValue)"
    }

    /// Appends " 2", " 3", ... before the extension until the name is free in `directory`.
    static func uniqueURL(in directory: URL, fileName: String) -> URL {
        var url = directory.appendingPathComponent(fileName)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }
        return url
    }

    static func crop(_ image: CGImage, toPixelRect rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rect.integral.intersection(bounds)
        guard clipped.width >= 1, clipped.height >= 1 else { return nil }
        return image.cropping(to: clipped)
    }

    /// Pads the image with transparent margins and draws a soft drop shadow under it.
    static func addingShadow(to image: CGImage, scale: CGFloat) -> CGImage {
        let padding = Int(56 * scale)
        let width = image.width + padding * 2
        let height = image.height + padding * 2
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale,
                          color: CGColor(gray: 0, alpha: 0.45))
        context.draw(image, in: CGRect(x: padding, y: padding, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }
}
