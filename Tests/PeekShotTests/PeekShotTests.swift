import Carbon.HIToolbox
import XCTest
@testable import PeekShot

private func solidImage(width: Int, height: Int, gray: CGFloat = 1) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// Reads one pixel as RGBA; `x`/`y` use a top-left origin like the rest of the app.
private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return data
}

final class GeometryTests: XCTestCase {
    func testRectFromPointsNormalizesDirection() {
        let rect = Geometry.rect(from: CGPoint(x: 50, y: 80), to: CGPoint(x: 10, y: 20))
        XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 40, height: 60))
    }

    func testSquareAndFromCenter() {
        let square = Geometry.rect(from: .zero, to: CGPoint(x: 30, y: -10), square: true)
        XCTAssertEqual(square, CGRect(x: 0, y: -30, width: 30, height: 30))
        let centered = Geometry.rect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 110, y: 120), fromCenter: true)
        XCTAssertEqual(centered, CGRect(x: 90, y: 80, width: 20, height: 40))
    }

    func testPixelRectFlipsVerticallyAndScales() {
        // A 100x50 pt selection whose top edge is 10 pt below the top of a 900 pt tall Retina display.
        let rect = Geometry.pixelRect(forViewRect: CGRect(x: 20, y: 840, width: 100, height: 50),
                                      viewHeight: 900, scale: 2, imageSize: CGSize(width: 2880, height: 1800))
        XCTAssertEqual(rect, CGRect(x: 40, y: 20, width: 200, height: 100))
    }

    func testPixelRectClampsToImage() {
        let rect = Geometry.pixelRect(forViewRect: CGRect(x: -10, y: -10, width: 50, height: 50),
                                      viewHeight: 100, scale: 1, imageSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(rect, CGRect(x: 0, y: 60, width: 40, height: 40))
    }

    func testGlobalAndViewConversionsOnSecondaryDisplay() {
        // A display placed to the right of and above the primary one.
        let display = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        let view = Geometry.viewRect(forGlobalRect: CGRect(x: 1540, y: -100, width: 300, height: 200),
                                     displayBounds: display)
        XCTAssertEqual(view, CGRect(x: 100, y: 780, width: 300, height: 200))
        let global = Geometry.globalPoint(forViewPoint: CGPoint(x: 100, y: 980), displayBounds: display)
        XCTAssertEqual(global, CGPoint(x: 1540, y: -100))
    }

    func testSnapAngleSnapsToDiagonal() {
        let snapped = Geometry.snapAngle(from: .zero, to: CGPoint(x: 100, y: 90))
        XCTAssertEqual(snapped.x, snapped.y, accuracy: 0.001)
    }

    func testDistanceToSegment() {
        let d = Geometry.distance(from: CGPoint(x: 5, y: 3), toSegment: .zero, CGPoint(x: 10, y: 0))
        XCTAssertEqual(d, 3, accuracy: 0.001)
        let beyond = Geometry.distance(from: CGPoint(x: 14, y: 3), toSegment: .zero, CGPoint(x: 10, y: 0))
        XCTAssertEqual(beyond, 5, accuracy: 0.001)
    }
}

final class KeyComboTests: XCTestCase {
    func testDisplayStringOrdersModifiers() {
        let combo = KeyCombo(keyCode: 0, modifiers: UInt32(cmdKey | shiftKey | controlKey | optionKey), key: "A")
        XCTAssertEqual(combo.displayString, "⌃⌥⇧⌘A")
    }

    func testCarbonModifierRoundTrip() {
        let flags: NSEvent.ModifierFlags = [.control, .option]
        let combo = KeyCombo(keyCode: 0, modifiers: KeyCombo.carbonModifiers(from: flags), key: "A")
        XCTAssertEqual(combo.cocoaModifiers, flags)
    }

    func testEveryActionHasDistinctDefault() {
        let codes = HotKeyAction.allCases.compactMap { $0.defaultCombo?.keyCode }
        XCTAssertEqual(Set(codes).count, HotKeyAction.allCases.count)
    }
}

final class ImageCodecTests: XCTestCase {
    func testCropUsesTopLeftOrigin() throws {
        // Top half white, bottom half black.
        let ctx = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 5, width: 10, height: 5))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 5))
        let image = ctx.makeImage()!

        let top = try XCTUnwrap(ImageCodec.crop(image, toPixelRect: CGRect(x: 0, y: 0, width: 10, height: 4)))
        XCTAssertEqual(top.height, 4)
        XCTAssertEqual(pixel(top, x: 5, y: 2)[0], 255)
        let bottom = try XCTUnwrap(ImageCodec.crop(image, toPixelRect: CGRect(x: 0, y: 6, width: 10, height: 4)))
        XCTAssertEqual(pixel(bottom, x: 5, y: 2)[0], 0)
    }

    func testCropRejectsEmptyRect() {
        XCTAssertNil(ImageCodec.crop(solidImage(width: 10, height: 10), toPixelRect: CGRect(x: 20, y: 20, width: 5, height: 5)))
    }

    func testShadowAddsTransparentPadding() {
        let image = ImageCodec.addingShadow(to: solidImage(width: 100, height: 60), scale: 2)
        XCTAssertEqual(image.width, 100 + 2 * 112)
        XCTAssertEqual(image.height, 60 + 2 * 112)
        XCTAssertEqual(pixel(image, x: 0, y: 0)[3], 0)
        XCTAssertEqual(pixel(image, x: image.width / 2, y: image.height / 2)[3], 255)
    }

    func testWriteAndLoadKeepsScale() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("peekshot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ImageCodec.write(solidImage(width: 40, height: 20), scale: 2, format: .png, to: url))
        let loaded = try XCTUnwrap(ImageCodec.load(url))
        XCTAssertEqual(loaded.scale, 2)
        XCTAssertEqual(loaded.pointSize, CGSize(width: 20, height: 10))
    }

    func testUniqueURLAvoidsCollisions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("peekshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ImageCodec.uniqueURL(in: directory, fileName: "shot.png")
        try Data().write(to: first)
        let second = ImageCodec.uniqueURL(in: directory, fileName: "shot.png")
        XCTAssertEqual(second.lastPathComponent, "shot 2.png")
    }

    func testMagnifiedPatchKeepsCursorPixelCentered() throws {
        // One red pixel at (0, 0); the patch around it must show it in the middle even at the image edge.
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 7, width: 1, height: 1)) // top-left pixel
        let patch = try XCTUnwrap(OverlayView.magnifiedPatch(of: ctx.makeImage()!, around: .zero, radius: 2))
        XCTAssertEqual(patch.width, 5)
        XCTAssertEqual(pixel(patch, x: 2, y: 2), [255, 0, 0, 255])
        XCTAssertEqual(pixel(patch, x: 3, y: 2), [255, 255, 255, 255])
    }
}

final class AnnotationTests: XCTestCase {
    private let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    func testFlattenKeepsPixelSizeAndDrawsLine() throws {
        let base = solidImage(width: 200, height: 100)
        var line = Annotation(kind: .line, at: CGPoint(x: 10, y: 10), color: red, size: 4)
        line.end = CGPoint(x: 90, y: 10)
        let image = try XCTUnwrap(AnnotationRenderer().flatten([line], base: base, scale: 2))
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 100)
        // The line runs along y = 10 pt, i.e. pixel row 20 from the top.
        XCTAssertEqual(pixel(image, x: 100, y: 20), [255, 0, 0, 255])
        XCTAssertEqual(pixel(image, x: 100, y: 80), [255, 255, 255, 255])
    }

    func testFilledRectangleCoversInterior() throws {
        let base = solidImage(width: 100, height: 100)
        var box = Annotation(kind: .rectangle, at: CGPoint(x: 20, y: 20), color: red, size: 2, filled: true)
        box.end = CGPoint(x: 60, y: 40)
        let image = try XCTUnwrap(AnnotationRenderer().flatten([box], base: base, scale: 1))
        XCTAssertEqual(pixel(image, x: 40, y: 30), [255, 0, 0, 255])
        XCTAssertEqual(pixel(image, x: 40, y: 60), [255, 255, 255, 255])
    }

    func testSpotlightDimsOutsideOnly() throws {
        let base = solidImage(width: 100, height: 100)
        var spot = Annotation(kind: .spotlight, at: CGPoint(x: 10, y: 10), color: red, size: 2)
        spot.end = CGPoint(x: 50, y: 50)
        let image = try XCTUnwrap(AnnotationRenderer().flatten([spot], base: base, scale: 1))
        XCTAssertEqual(pixel(image, x: 30, y: 30)[0], 255)
        XCTAssertLessThan(pixel(image, x: 80, y: 80)[0], 140)
    }

    func testPixelateChangesCheckerboardRegionOnly() throws {
        // A 1 px checkerboard averages to gray once pixelated.
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<64 {
            for x in 0..<64 {
                ctx.setFillColor(CGColor(gray: (x + y) % 2 == 0 ? 1 : 0, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let base = ctx.makeImage()!
        var mosaic = Annotation(kind: .pixelate, at: .zero, color: red, size: 4)
        mosaic.end = CGPoint(x: 32, y: 32)
        let image = try XCTUnwrap(AnnotationRenderer().flatten([mosaic], base: base, scale: 1))
        let inside = pixel(image, x: 10, y: 10)[0]
        XCTAssertTrue(inside > 60 && inside < 200, "expected a mid gray, got \(inside)")
        let outside = pixel(image, x: 50, y: 50)[0]
        XCTAssertTrue(outside == 0 || outside == 255)
    }

    func testOutlinedRectangleHitsBorderOnly() {
        var box = Annotation(kind: .rectangle, at: .zero, color: red, size: 2)
        box.end = CGPoint(x: 100, y: 100)
        XCTAssertTrue(box.hitTest(CGPoint(x: 1, y: 50)))
        XCTAssertFalse(box.hitTest(CGPoint(x: 50, y: 50)))
        box.filled = true
        XCTAssertTrue(box.hitTest(CGPoint(x: 50, y: 50)))
    }

    func testTranslateMovesFreehandPoints() {
        var stroke = Annotation(kind: .pencil, at: .zero, color: red, size: 2)
        stroke.points = [.zero, CGPoint(x: 10, y: 10)]
        stroke.translate(dx: 5, dy: -5)
        XCTAssertEqual(stroke.points, [CGPoint(x: 5, y: -5), CGPoint(x: 15, y: 5)])
    }

    func testTinyShapesAreDiscarded() {
        var arrow = Annotation(kind: .arrow, at: .zero, color: red, size: 2)
        arrow.end = CGPoint(x: 1, y: 1)
        XCTAssertFalse(arrow.isSubstantial)
        arrow.end = CGPoint(x: 30, y: 0)
        XCTAssertTrue(arrow.isSubstantial)
    }
}

final class HistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("peekshot-history-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAddListsNewestFirstAndDeleteRemovesFile() throws {
        let store = HistoryStore(directory: directory)
        let first = store.add(image: solidImage(width: 4, height: 4), scale: 1, date: Date(timeIntervalSince1970: 1000))
        let second = store.add(image: solidImage(width: 4, height: 4), scale: 1, date: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertNotEqual(first.fileURL, second.fileURL)

        let entry = try XCTUnwrap(store.entries.first)
        store.delete(entry)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.url.path))
    }

    func testPruneRemovesOnlyOldEntries() throws {
        let store = HistoryStore(directory: directory)
        let old = try XCTUnwrap(store.add(image: solidImage(width: 4, height: 4), scale: 1).fileURL)
        let fresh = try XCTUnwrap(store.add(image: solidImage(width: 4, height: 4), scale: 1,
                                            date: Date(timeIntervalSinceNow: 60)).fileURL)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -40 * 86_400)],
                                              ofItemAtPath: old.path)
        store.reload()
        store.prune(olderThanDays: 30)
        XCTAssertEqual(store.entries.map(\.url.lastPathComponent), [fresh.lastPathComponent])

        store.prune(olderThanDays: 0)
        XCTAssertEqual(store.entries.count, 1, "zero days keeps everything")
    }
}

final class TextRecognizerTests: XCTestCase {
    func testRecognizesRenderedText() async throws {
        // Dark text on white, large enough for accurate recognition.
        let width = 900, height = 220
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: "PeekShot reads 12345", attributes: [
            .font: NSFont.systemFont(ofSize: 64, weight: .medium), .foregroundColor: NSColor.black,
        ]).draw(at: CGPoint(x: 40, y: 70))
        NSGraphicsContext.restoreGraphicsState()

        let text = await TextRecognizer.recognize(in: ctx.makeImage()!)
        XCTAssertTrue(text.contains("PeekShot"), "got: \(text)")
        XCTAssertTrue(text.contains("12345"), "got: \(text)")
    }

    func testBlankImageYieldsNoText() async {
        let text = await TextRecognizer.recognize(in: solidImage(width: 200, height: 100))
        XCTAssertEqual(text, "")
    }
}

final class QuickAccessThumbnailTests: XCTestCase {
    @MainActor
    func testThumbnailFillsCardAndKeepsSmallCapturesCentered() throws {
        let size = QuickAccessController.cardSize
        // A large capture fills the whole card.
        let large = CaptureItem(image: solidImage(width: 2000, height: 1000, gray: 1), scale: 2)
        let filled = try XCTUnwrap(QuickAccessCardView.thumbnail(of: large, size: size, scale: 2))
        XCTAssertEqual(filled.width, Int(size.width) * 2)
        XCTAssertEqual(pixel(filled, x: 2, y: 2)[0], 255)

        // A small capture keeps its natural size on a dark backdrop.
        let small = CaptureItem(image: solidImage(width: 40, height: 40, gray: 1), scale: 2)
        let centered = try XCTUnwrap(QuickAccessCardView.thumbnail(of: small, size: size, scale: 2))
        XCTAssertLessThan(pixel(centered, x: 2, y: 2)[0], 60)
        XCTAssertEqual(pixel(centered, x: centered.width / 2, y: centered.height / 2)[0], 255)
    }
}
