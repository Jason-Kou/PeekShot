import AppKit

/// What happens to a capture: the automatic steps right after it is taken, and the actions shared by
/// the quick access card, the editor, pinned images and the history window.
@MainActor
enum CaptureActions {
    static func deliver(image: CGImage, scale: CGFloat, on screen: NSScreen) {
        if Prefs.playSound { playShutter() }
        let item = HistoryStore.shared.add(image: image, scale: scale)
        if Prefs.copyAfterCapture { ImageCodec.copyToPasteboard(item) }
        if Prefs.saveAfterCapture { save(item, announce: false) }
        if Prefs.showQuickAccess {
            QuickAccessController.shared.show(item, on: screen)
        } else if Prefs.copyAfterCapture {
            Toast.show("已复制到剪贴板")
        } else if Prefs.saveAfterCapture {
            Toast.show("已保存")
        }
    }

    static func copy(_ item: CaptureItem) {
        ImageCodec.copyToPasteboard(item)
        Toast.show("已复制到剪贴板")
    }

    /// Saves into the folder from settings.
    @discardableResult
    static func save(_ item: CaptureItem, announce: Bool = true) -> URL? {
        let format = Prefs.imageFormat
        let directory = Prefs.saveDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = ImageCodec.uniqueURL(in: directory, fileName: ImageCodec.fileName(for: Date(), format: format))
        guard ImageCodec.write(item.image, scale: item.scale, format: format, to: url) else {
            Toast.show("保存失败：无法写入 \(directory.lastPathComponent)")
            return nil
        }
        if announce { Toast.show("已保存到 \(directory.lastPathComponent)") }
        return url
    }

    static func saveAs(_ item: CaptureItem, relativeTo window: NSWindow? = nil) {
        let format = Prefs.imageFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = ImageCodec.fileName(for: Date(), format: format)
        panel.directoryURL = Prefs.saveDirectory
        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            if !ImageCodec.write(item.image, scale: item.scale, format: format, to: url) {
                Toast.show("保存失败")
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            write(panel.runModal())
        }
    }

    static func edit(_ item: CaptureItem) {
        EditorWindowController.open(item)
    }

    static func pin(_ item: CaptureItem) {
        PinWindowController.pin(item)
    }

    static func revealInFinder(_ item: CaptureItem) {
        guard let url = item.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static let shutter = NSSound(contentsOfFile:
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true)

    private static func playShutter() {
        shutter?.stop()
        shutter?.play()
    }
}

/// A short status message near the bottom of the screen.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static var windowNumber: Int? { panel?.windowNumber }

    static func show(_ message: String) {
        hideWork?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 32, height: label.frame.height + 18)
        let screen = NSScreen.underMouse
        let origin = CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 80)

        let panel = NSPanel(contentRect: CGRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let background = NSView(frame: CGRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        background.layer?.cornerRadius = size.height / 2
        label.frame.origin = CGPoint(x: 16, y: 9)
        background.addSubview(label)
        panel.contentView = background
        panel.orderFrontRegardless()
        self.panel = panel

        let work = DispatchWorkItem { panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}
