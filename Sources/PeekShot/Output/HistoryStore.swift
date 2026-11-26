import AppKit

struct HistoryEntry: Identifiable, Hashable {
    let url: URL
    let date: Date
    var id: URL { url }
}

/// Keeps recent captures as PNG files in one folder; the folder listing is the index.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PeekShot/History", isDirectory: true))

    let directory: URL
    @Published private(set) var entries: [HistoryEntry] = []

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                 options: .skipsHiddenFiles)) ?? []
        entries = urls
            .filter { $0.pathExtension.lowercased() == "png" }
            .map { url in
                let date = (try? url.resourceValues(forKeys: Set(keys)))?.creationDate ?? .distantPast
                return HistoryEntry(url: url, date: date)
            }
            .sorted { $0.date > $1.date }
    }

    @discardableResult
    func add(image: CGImage, scale: CGFloat, date: Date = Date()) -> CaptureItem {
        let url = ImageCodec.uniqueURL(in: directory, fileName: ImageCodec.fileName(for: date, format: .png))
        let stored = ImageCodec.write(image, scale: scale, format: .png, to: url)
        reload()
        return CaptureItem(image: image, scale: scale, fileURL: stored ? url : nil)
    }

    /// Rewrites the stored file after the item was edited.
    func update(_ item: CaptureItem) {
        guard let url = item.fileURL, url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
        else { return }
        ImageCodec.write(item.image, scale: item.scale, format: .png, to: url)
        ThumbnailCache.shared.invalidate(url)
        reload()
    }

    func delete(_ entry: HistoryEntry) {
        try? FileManager.default.removeItem(at: entry.url)
        reload()
    }

    func deleteAll() {
        entries.forEach { try? FileManager.default.removeItem(at: $0.url) }
        reload()
    }

    /// Removes captures older than `days`; zero or less keeps everything.
    func prune(olderThanDays days: Int, now: Date = Date()) {
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        entries.filter { $0.date < cutoff }.forEach { try? FileManager.default.removeItem(at: $0.url) }
        reload()
    }
}

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let thumbnail = ImageCodec.thumbnail(for: url, maxPixelSize: 520) else { return nil }
        let image = NSImage(cgImage: thumbnail, size: .zero)
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    func invalidate(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }
}
