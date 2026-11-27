import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Scrolling capture: watches a region while its content scrolls and stitches the frames into one tall image.
///
/// The region stays live: the frame around it ignores the mouse, so the user scrolls the app underneath
/// with the trackpad or wheel. Auto-Scroll posts the scroll events itself, which needs the Accessibility
/// permission. Esc cancels and Return finishes, even while the captured app is active.
@MainActor
final class ScrollingCaptureSession: NSObject {
    private static var current: ScrollingCaptureSession?

    private enum State { case running, finishing, cancelled }

    /// The region in global AppKit coordinates (bottom-left origin).
    private let screenRect: CGRect
    /// The region in display points with a top-left origin, as ScreenCaptureKit expects.
    private let sourceRect: CGRect
    private let displayID: CGDirectDisplayID
    private let scale: CGFloat
    private let completion: (CGImage?) -> Void

    private var state = State.running
    private var stitcher: ScrollStitcher?
    private var autoScrolling = false
    /// Auto-scroll steps in a row that did not move the content.
    private var stalledSteps = 0
    private var lastPreview = Date.distantPast

    private var frameWindow: NSPanel!
    private var controlPanel: NSPanel!
    private var previewPanel: NSPanel?
    private let previewView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "Scroll down inside the frame")
    private var autoButton: NSButton!

    private static let previewWidth: CGFloat = 150
    private static let margin: CGFloat = 10

    /// Starts a session on `viewRect` (view coordinates of `screen`). `completion` gets the stitched image,
    /// or nil when cancelled.
    static func start(screen: NSScreen, displayID: CGDirectDisplayID, viewRect: CGRect, scale: CGFloat,
                      completion: @escaping (CGImage?) -> Void) {
        let session = ScrollingCaptureSession(screen: screen, displayID: displayID, viewRect: viewRect,
                                              scale: scale, completion: completion)
        current = session
        session.begin()
    }

    private init(screen: NSScreen, displayID: CGDirectDisplayID, viewRect: CGRect, scale: CGFloat,
                 completion: @escaping (CGImage?) -> Void) {
        screenRect = viewRect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        sourceRect = CGRect(x: viewRect.minX, y: screen.frame.height - viewRect.maxY,
                            width: viewRect.width, height: viewRect.height)
        self.displayID = displayID
        self.scale = scale
        self.completion = completion
        super.init()
        frameWindow = makeFrameWindow()
        controlPanel = makeControlPanel(on: screen)
        previewPanel = makePreviewPanel(on: screen)
    }

    private var ownWindows: [NSWindow] { [frameWindow, controlPanel, previewPanel].compactMap { $0 } }

    private func begin() {
        ownWindows.forEach { $0.orderFrontRegardless() }
        HotKeyCenter.shared.addTransientKey(keyCode: kVK_Escape) { [weak self] in self?.cancel() }
        HotKeyCenter.shared.addTransientKey(keyCode: kVK_Return) { [weak self] in self?.done() }
        Task { await run() }
    }

    // MARK: Capture loop

    private func run() async {
        do {
            // The window server lists our panels only once they are on screen.
            try await Task.sleep(nanoseconds: 150_000_000)
            let filter = try await ScreenCapturer.displayFilter(displayID: displayID,
                                                                excluding: Set(ownWindows.map(\.windowNumber)))
            while state == .running {
                if autoScrolling {
                    postScroll()
                    // Give the app time to draw the new position.
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                let frame = try await ScreenCapturer.capture(sourceRect, with: filter)
                guard state != .cancelled else { break }
                await process(frame)
                if !autoScrolling { try await Task.sleep(nanoseconds: 40_000_000) }
            }
        } catch {
            if state == .running {
                state = .cancelled
                Toast.show("Scrolling capture failed: \(error.localizedDescription)")
            }
        }
        await end()
    }

    private func process(_ frame: CGImage) async {
        guard let stitcher else {
            stitcher = ScrollStitcher(first: frame)
            await updatePreview(force: true)
            return
        }
        let result = await Task.detached { stitcher.add(frame) }.value
        switch result {
        case .appended:
            stalledSteps = 0
            setStatus("\(Int(CGFloat(stitcher.width) / scale)) × \(Int(CGFloat(stitcher.height) / scale))")
            await updatePreview()
        case .unchanged, .noMatch:
            if result == .noMatch { setStatus("Lost track: scroll back a little, then slower") }
            // Something animating in the region (a caret, a spinner) turns the end of the page into
            // no-match frames rather than unchanged ones, so both count towards stopping.
            guard autoScrolling else { break }
            stalledSteps += 1
            if stalledSteps >= 5 {
                stopAutoScroll()
                setStatus("Reached the end. Press Done to finish")
            }
        case .full:
            stopAutoScroll()
            setStatus("Maximum length reached. Press Done to finish")
        }
    }

    /// Shows the stitched image so far; throttled because rebuilding a tall image is not free.
    private func updatePreview(force: Bool = false) async {
        guard let stitcher, previewPanel != nil else { return }
        guard force || Date().timeIntervalSince(lastPreview) > 0.3 else { return }
        lastPreview = Date()
        let maxWidth = Int(Self.previewWidth * scale)
        let thumbnail = await Task.detached { Self.thumbnail(of: stitcher.makeImage(), maxWidth: maxWidth) }.value
        if let thumbnail {
            previewView.image = NSImage(cgImage: thumbnail, size: CGSize(width: CGFloat(thumbnail.width) / scale,
                                                                         height: CGFloat(thumbnail.height) / scale))
        }
    }

    nonisolated private static func thumbnail(of image: CGImage?, maxWidth: Int) -> CGImage? {
        guard let image else { return nil }
        guard image.width > maxWidth else { return image }
        let ratio = CGFloat(maxWidth) / CGFloat(image.width)
        let height = max(1, Int(CGFloat(image.height) * ratio))
        guard let context = CGContext(data: nil, width: maxWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: height))
        return context.makeImage()
    }

    private func end() async {
        stopAutoScroll()
        HotKeyCenter.shared.removeTransientKeys()
        ownWindows.forEach { $0.orderOut(nil) }
        var image: CGImage?
        if state == .finishing, let stitcher {
            image = await Task.detached { stitcher.makeImage() }.value
        }
        Self.current = nil
        completion(image)
    }

    // MARK: Actions

    @objc private func done() {
        guard state == .running else { return }
        state = .finishing
    }

    @objc private func cancel() {
        guard state == .running else { return }
        state = .cancelled
    }

    @objc private func toggleAutoScroll() {
        if autoScrolling {
            stopAutoScroll()
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            setStatus("Allow PeekShot under Accessibility to auto-scroll")
            return
        }
        autoScrolling = true
        stalledSteps = 0
        autoButton.title = "Stop"
        autoButton.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
        // Scroll events go to the window under the pointer: put it inside the frame once.
        if !NSMouseInRect(NSEvent.mouseLocation, screenRect, false) { CGWarpMouseCursorPosition(globalCenter) }
    }

    private func stopAutoScroll() {
        guard autoScrolling else { return }
        autoScrolling = false
        autoButton.title = "Auto-Scroll"
        autoButton.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
    }

    /// The region's center in Quartz coordinates (top-left origin of the primary display).
    private var globalCenter: CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: screenRect.midX, y: primaryHeight - screenRect.midY)
    }

    private func postScroll() {
        // The events go wherever the pointer is; never pull it back. Moving it out of the frame is
        // how the user takes over again.
        guard NSMouseInRect(NSEvent.mouseLocation, screenRect, false) else {
            stopAutoScroll()
            setStatus("Auto-Scroll stopped: the pointer left the frame")
            return
        }
        // A third of the region per step keeps plenty of overlap between frames for the stitcher.
        let step = Int32(max(20, sourceRect.height / 3))
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -step, wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    // MARK: Windows

    private static func makePanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    /// A border just outside the region that lets every mouse event through to the app below.
    private func makeFrameWindow() -> NSPanel {
        let inset: CGFloat = 3
        let panel = Self.makePanel(frame: screenRect.insetBy(dx: -inset, dy: -inset))
        panel.ignoresMouseEvents = true
        let view = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        view.wantsLayer = true
        let border = CAShapeLayer()
        border.path = CGPath(rect: view.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        border.fillColor = nil
        border.strokeColor = NSColor.controlAccentColor.cgColor
        border.lineWidth = 2
        border.lineDashPattern = [6, 4]
        view.layer?.addSublayer(border)
        panel.contentView = view
        return panel
    }

    /// Status, Auto-Scroll, Cancel and Done, below the region when there is room.
    private func makeControlPanel(on screen: NSScreen) -> NSPanel {
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.widthAnchor.constraint(equalToConstant: 270).isActive = true

        autoButton = Self.button("Auto-Scroll", symbol: "arrow.down.circle", target: self,
                                 action: #selector(toggleAutoScroll))
        let cancelButton = Self.button("Cancel", symbol: nil, target: self, action: #selector(cancel))
        let doneButton = Self.button("Done", symbol: "checkmark", target: self, action: #selector(done))
        doneButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [statusLabel, autoButton, cancelButton, doneButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 8)
        let size = stack.fittingSize

        let visible = screen.visibleFrame
        var origin = CGPoint(x: screenRect.midX - size.width / 2, y: screenRect.minY - Self.margin - size.height)
        if origin.y < visible.minY { origin.y = screenRect.maxY + Self.margin }
        if origin.y + size.height > visible.maxY { origin.y = screenRect.minY + Self.margin }
        origin.x = min(max(origin.x, visible.minX + Self.margin), visible.maxX - Self.margin - size.width)

        let panel = Self.makePanel(frame: CGRect(origin: origin, size: size))
        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .vibrantDark)
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        stack.frame = background.bounds
        stack.autoresizingMask = [.width, .height]
        background.addSubview(stack)
        panel.contentView = background
        return panel
    }

    /// The stitched image so far, beside the region; left out when neither side has room.
    private func makePreviewPanel(on screen: NSScreen) -> NSPanel? {
        let visible = screen.visibleFrame
        let width = Self.previewWidth + 12
        let x: CGFloat
        if screenRect.maxX + Self.margin + width <= visible.maxX {
            x = screenRect.maxX + Self.margin
        } else if screenRect.minX - Self.margin - width >= visible.minX {
            x = screenRect.minX - Self.margin - width
        } else {
            return nil
        }
        let height = min(max(screenRect.height, 120), visible.height)
        let y = min(max(screenRect.maxY - height, visible.minY), visible.maxY - height)
        let panel = Self.makePanel(frame: CGRect(x: x, y: y, width: width, height: height))
        panel.ignoresMouseEvents = true

        let background = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        previewView.frame = background.bounds.insetBy(dx: 6, dy: 6)
        previewView.autoresizingMask = [.width, .height]
        previewView.imageScaling = .scaleProportionallyDown
        previewView.imageAlignment = .alignTop
        background.addSubview(previewView)
        panel.contentView = background
        return panel
    }

    private static func button(_ title: String, symbol: String?, target: AnyObject, action: Selector) -> NSButton {
        let button = FirstMouseButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
        }
        return button
    }
}

/// Clicks land on the first try even though the panel never becomes key.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
