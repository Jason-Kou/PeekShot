import XCTest
@testable import PeekShot

/// Builds RGBA images row by row; every row of `content` gets its own pseudo-random pattern.
private struct Page {
    let width: Int
    let rows: [[UInt8]]

    init(width: Int, height: Int, seed: UInt64) {
        self.width = width
        var state = seed
        var rows: [[UInt8]] = []
        for _ in 0..<height {
            var row = [UInt8](repeating: 255, count: width * 4)
            for x in 0..<width {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                row[x * 4] = UInt8(truncatingIfNeeded: state >> 24)
                row[x * 4 + 1] = UInt8(truncatingIfNeeded: state >> 32)
                row[x * 4 + 2] = UInt8(truncatingIfNeeded: state >> 40)
            }
            rows.append(row)
        }
        self.rows = rows
    }

    init(width: Int, rows: [[UInt8]]) {
        self.width = width
        self.rows = rows
    }

    func slice(_ range: Range<Int>) -> [[UInt8]] { Array(rows[range]) }
}

private func makeImage(width: Int, rows: [[UInt8]]) -> CGImage {
    let bytes = rows.flatMap { $0 }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: width, height: rows.count, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private func rows(of image: CGImage) -> [[UInt8]] {
    let width = image.width, height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (0..<height).map { Array(data[($0 * width * 4)..<(($0 + 1) * width * 4)]) }
}

final class ScrollStitcherTests: XCTestCase {
    private let width = 24

    /// A viewport of `band` rows showing `content` from `offset`, between a fixed header and footer.
    private func frame(_ content: Page, offset: Int, band: Int, header: Page? = nil, footer: Page? = nil) -> CGImage {
        let rows = (header?.rows ?? []) + content.slice(offset..<(offset + band)) + (footer?.rows ?? [])
        return makeImage(width: width, rows: rows)
    }

    func testStitchesPlainScrollingIntoOnePage() {
        let content = Page(width: width, height: 400, seed: 1)
        let stitcher = ScrollStitcher(first: frame(content, offset: 0, band: 100))
        for offset in [30, 75, 140, 220, 300] {
            XCTAssertEqual(stitcher.add(frame(content, offset: offset, band: 100)), .appended)
        }
        XCTAssertEqual(stitcher.height, 400)
        XCTAssertEqual(rows(of: stitcher.makeImage()!), content.rows)
    }

    func testKeepsStickyHeaderAndFooterOnce() {
        let content = Page(width: width, height: 300, seed: 2)
        let header = Page(width: width, height: 12, seed: 3)
        let footer = Page(width: width, height: 9, seed: 4)
        let stitcher = ScrollStitcher(first: frame(content, offset: 0, band: 80, header: header, footer: footer))
        for offset in [20, 60, 110, 170, 220] {
            XCTAssertEqual(stitcher.add(frame(content, offset: offset, band: 80, header: header, footer: footer)),
                           .appended)
        }
        let expected = header.rows + content.rows + footer.rows
        XCTAssertEqual(rows(of: stitcher.makeImage()!), expected)
    }

    func testBottomEdgeThatChangesWithContentAppearsOnlyAtTheEnd() {
        // A window's rounded bottom corners: the corner pixels stay put but the content shows between them,
        // so those rows differ in every frame and are not detected as a static footer.
        let content = Page(width: width, height: 300, seed: 10)
        let corner = 3, edge = 4
        func frameWithCorners(offset: Int) -> CGImage {
            var rows = content.slice(offset..<(offset + 100))
            for index in (rows.count - edge)..<rows.count {
                for x in Array(0..<corner) + Array((width - corner)..<width) {
                    rows[index].replaceSubrange((x * 4)..<(x * 4 + 4), with: [0, 0, 0, 0])
                }
            }
            return makeImage(width: width, rows: rows)
        }
        let stitcher = ScrollStitcher(first: frameWithCorners(offset: 0))
        for offset in [30, 70, 120, 170, 200] {
            XCTAssertEqual(stitcher.add(frameWithCorners(offset: offset)), .appended)
        }
        let result = rows(of: stitcher.makeImage()!)
        XCTAssertEqual(result.count, 300)
        // Everything above the last frame's edge is clean content.
        XCTAssertEqual(Array(result[0..<(300 - edge)]), content.slice(0..<(300 - edge)))
    }

    func testIgnoresUnchangedFrames() {
        let content = Page(width: width, height: 200, seed: 5)
        let stitcher = ScrollStitcher(first: frame(content, offset: 0, band: 100))
        XCTAssertEqual(stitcher.add(frame(content, offset: 0, band: 100)), .unchanged)
        XCTAssertEqual(stitcher.height, 100)
    }

    func testRejectsJumpsWithoutOverlap() {
        let content = Page(width: width, height: 400, seed: 6)
        let stitcher = ScrollStitcher(first: frame(content, offset: 0, band: 100))
        XCTAssertEqual(stitcher.add(frame(content, offset: 150, band: 100)), .noMatch)
        XCTAssertEqual(stitcher.height, 100)
        // The next frame that overlaps the last stitched one continues the page.
        XCTAssertEqual(stitcher.add(frame(content, offset: 60, band: 100)), .appended)
        XCTAssertEqual(rows(of: stitcher.makeImage()!), content.slice(0..<160))
    }

    func testIgnoresScrollingBackUp() {
        let content = Page(width: width, height: 300, seed: 7)
        let stitcher = ScrollStitcher(first: frame(content, offset: 0, band: 100))
        XCTAssertEqual(stitcher.add(frame(content, offset: 80, band: 100)), .appended)
        XCTAssertEqual(stitcher.add(frame(content, offset: 40, band: 100)), .noMatch)
        XCTAssertEqual(stitcher.height, 180)
    }

    func testStopsGrowingAtTheSizeLimit() {
        let content = Page(width: width, height: 400, seed: 9)
        // Room for 150 rows of 24 RGBA pixels.
        let stitcher = ScrollStitcher(first: frame(content, offset: 0, band: 100), maxBytes: 150 * width * 4)
        XCTAssertEqual(stitcher.add(frame(content, offset: 40, band: 100)), .appended)
        XCTAssertEqual(stitcher.add(frame(content, offset: 80, band: 100)), .full)
        XCTAssertEqual(stitcher.height, 140)
    }

    func testRepeatedRowsDoNotConfuseTheMatch() {
        // A page with large blank gaps between blocks of text-like rows.
        let noise = Page(width: width, height: 400, seed: 8)
        let blank = [UInt8](repeating: 255, count: width * 4)
        let mixed = noise.rows.enumerated().map { index, row in (index / 25) % 2 == 0 ? row : blank }
        let content = Page(width: width, rows: mixed)
        let stitcher = ScrollStitcher(first: frame(content, offset: 0, band: 120))
        for offset in [45, 90, 160, 230, 280] {
            XCTAssertEqual(stitcher.add(frame(content, offset: offset, band: 120)), .appended)
        }
        XCTAssertEqual(rows(of: stitcher.makeImage()!), content.rows)
    }
}

/// Stitches frames of a real AppKit text view scrolled to different offsets, with a sticky header above it.
@MainActor
final class ScrollStitcherRenderTests: XCTestCase {
    func testStitchesRenderedTextViewExactly() throws {
        let size = CGSize(width: 360, height: 260)
        let header: CGFloat = 20
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        let label = NSTextField(labelWithString: "Sticky header")
        label.frame = CGRect(x: 8, y: size.height - header + 2, width: 200, height: 16)
        container.addSubview(label)

        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: size.width, height: size.height - header))
        scrollView.hasVerticalScroller = false
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.string = (1...160).map { "Line \($0): " + String(repeating: "lorem ipsum ", count: $0 % 5 + 1) }
            .joined(separator: "\n")
        scrollView.documentView = textView
        container.addSubview(scrollView)

        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.sizeToFit()

        func frame(at offset: CGFloat) -> (CGImage, CGFloat) {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            container.layoutSubtreeIfNeeded()
            let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds)!
            container.cacheDisplay(in: container.bounds, to: rep)
            return (rep.cgImage!, scrollView.contentView.bounds.minY)
        }

        let (first, _) = frame(at: 0)
        let scale = CGFloat(first.height) / size.height
        let stitcher = ScrollStitcher(first: first)
        var lastOffset: CGFloat = 0
        for offset: CGFloat in [33, 71.5, 120, 180.5, 250, 333, 401, 470, 552] {
            let (image, actual) = frame(at: offset)
            XCTAssertEqual(stitcher.add(image), .appended, "offset \(offset)")
            lastOffset = actual
        }
        XCTAssertGreaterThan(lastOffset, 500, "the document must be long enough to scroll")
        XCTAssertEqual(stitcher.height, first.height + Int((lastOffset * scale).rounded()))

        if let directory = ProcessInfo.processInfo.environment["PEEKSHOT_SNAPSHOT_DIR"], let image = stitcher.makeImage() {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            ImageCodec.write(image, scale: scale, format: .png,
                             to: URL(fileURLWithPath: directory).appendingPathComponent("scrolling-stitched.png"))
        }
    }
}
