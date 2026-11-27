import CoreGraphics
import Foundation

/// Joins successive captures of a region that scrolls downwards into one tall image.
///
/// Each frame is matched against the previous one by comparing row hashes: the vertical offset that
/// lines up the most distinct rows wins. Rows that stay put at the bottom of the region (a sticky
/// footer or toolbar) are kept once at the very end; rows that stay put at the top (a sticky header)
/// are never matched, so they only appear once at the top.
final class ScrollStitcher: @unchecked Sendable {
    enum Result: Equatable {
        /// New rows were added to the bottom of the image.
        case appended
        /// The frame equals the previous one: nothing scrolled.
        case unchanged
        /// No offset fits: the content scrolled up, jumped too far, or changed in place.
        case noMatch
        /// The image reached `maxHeight`; the frame was not added.
        case full
    }

    let width: Int
    let frameHeight: Int
    private let bytesPerRow: Int
    private let colorSpace: CGColorSpace
    private var pixels: [UInt8]
    private var previousHashes: [Int]

    /// Rows that can be stitched before memory use gets out of hand.
    let maxHeight: Int

    var height: Int { pixels.count / bytesPerRow }

    init(first frame: CGImage, maxBytes: Int = 384 << 20) {
        width = frame.width
        frameHeight = frame.height
        bytesPerRow = frame.width * 4
        let space = frame.colorSpace
        colorSpace = space?.model == .rgb ? space! : CGColorSpace(name: CGColorSpace.sRGB)!
        maxHeight = max(frame.height, maxBytes / max(1, bytesPerRow))
        pixels = Self.rgba(of: frame, colorSpace: colorSpace)
        previousHashes = Self.rowHashes(of: pixels, bytesPerRow: bytesPerRow)
    }

    func add(_ frame: CGImage) -> Result {
        guard frame.width == width, frame.height == frameHeight else { return .noMatch }
        let current = Self.rgba(of: frame, colorSpace: colorSpace)
        let hashes = Self.rowHashes(of: current, bytesPerRow: bytesPerRow)
        if hashes == previousHashes { return .unchanged }
        guard let offset = Self.offset(from: previousHashes, to: hashes) else { return .noMatch }

        // Rows at the bottom that did not move belong to a sticky footer. The bottom edge is always
        // treated as one too: rounded window corners or a fade-out change with the content behind them,
        // and would otherwise be stitched in at every seam. Content taken from above the edge replaces it.
        let h = frameHeight
        var footer = 0
        while footer < h - offset, hashes[h - 1 - footer] == previousHashes[h - 1 - footer] { footer += 1 }
        footer = max(footer, min(Self.bottomEdge(frameHeight: h), h - offset))

        guard height + offset <= maxHeight else { return .full }
        // The image always ends with the previous frame, footer included. Swap that footer for the
        // rows that scrolled into view plus the current footer.
        pixels.removeLast(footer * bytesPerRow)
        pixels.append(contentsOf: current[((h - footer - offset) * bytesPerRow)...])
        previousHashes = hashes
        return .appended
    }

    func makeImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Matching

    /// Rows at the bottom of every frame that only count for the last frame.
    static func bottomEdge(frameHeight: Int) -> Int { min(frameHeight / 8, 96) }

    /// The downward scroll distance in rows, i.e. the `d > 0` for which `current[i] == previous[i + d]`
    /// holds for the most distinct rows.
    static func offset(from previous: [Int], to current: [Int]) -> Int? {
        var positions: [Int: [Int]] = [:]
        for (index, hash) in previous.enumerated() {
            positions[hash, default: []].append(index)
        }
        var votes: [Int: Int] = [:]
        for (index, hash) in current.enumerated() {
            // Blank and repeated rows fit many offsets; only rows that are nearly unique get a vote.
            guard let matches = positions[hash], matches.count <= 2 else { continue }
            for match in matches where match > index {
                votes[match - index, default: 0] += 1
            }
        }
        let minimumVotes = 3
        guard let best = votes.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
              best.value >= minimumVotes else { return nil }
        return best.key
    }

    private static func rgba(of image: CGImage, colorSpace: CGColorSpace) -> [UInt8] {
        let bytesPerRow = image.width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    private static func rowHashes(of pixels: [UInt8], bytesPerRow: Int) -> [Int] {
        pixels.withUnsafeBytes { buffer in
            stride(from: 0, to: buffer.count, by: bytesPerRow).map { start in
                var hasher = Hasher()
                hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: buffer[start..<(start + bytesPerRow)]))
                return hasher.finalize()
            }
        }
    }
}
