import AppKit

enum SelectionMode {
    case area, window
}

enum SelectionOutcome {
    /// `rect` is in view coordinates of the snapshot's screen (points, bottom-left origin).
    case area(snapshot: DisplaySnapshot, rect: CGRect)
    case window(snapshot: DisplaySnapshot, window: WindowInfo)
    case cancelled
}

/// Shows a frozen still of every display and lets the user pick an area or a window.
final class SelectionSession {
    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var keyMonitor: Any?
    private var completion: ((SelectionOutcome) -> Void)?
    private let previousApp = NSWorkspace.shared.frontmostApplication

    init(snapshots: [DisplaySnapshot], windowInfos: [WindowInfo], mode: SelectionMode) {
        for snapshot in snapshots {
            let window = OverlayWindow(contentRect: snapshot.screen.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = true
            window.hasShadow = false
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = OverlayView(snapshot: snapshot, windowInfos: windowInfos, mode: mode)
            view.session = self
            window.contentView = view
            window.setFrame(snapshot.screen.frame, display: false)
            windows.append(window)
            views.append(view)
        }
    }

    func begin(completion: @escaping (SelectionOutcome) -> Void) {
        self.completion = completion
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        for window in windows {
            window.orderFrontRegardless()
            if NSMouseInRect(mouse, window.frame, false) {
                window.makeKeyAndOrderFront(nil)
                (window.contentView as? OverlayView)?.mouseArrived(at: window.convertPoint(fromScreen: mouse))
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            (self?.handleKey(event) ?? false) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // escape
            if event.type == .keyDown { finish(.cancelled) }
            return true
        case 49: // space: move the selection while dragging, otherwise toggle window mode
            if event.type == .keyUp {
                views.forEach { $0.spaceHeld = false }
            } else if !event.isARepeat {
                if views.contains(where: { $0.isDragging }) {
                    views.forEach { $0.spaceHeld = true }
                } else {
                    views.forEach { $0.mode = $0.mode == .area ? .window : .area }
                }
            }
            return true
        default:
            return false
        }
    }

    fileprivate func finish(_ outcome: SelectionOutcome) {
        guard let completion else { return }
        self.completion = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        previousApp?.activate()
        completion(outcome)
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A rounded dark label that sizes itself to its text.
private final class LabelLayer: CALayer {
    private let textLayer = CATextLayer()
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    init(contentsScale scale: CGFloat) {
        super.init()
        backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        cornerRadius = 4
        textLayer.contentsScale = scale
        textLayer.font = font
        textLayer.fontSize = font.pointSize
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.alignmentMode = .center
        addSublayer(textLayer)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setText(_ text: String) {
        let size = (text as NSString).size(withAttributes: [.font: font])
        textLayer.string = text
        bounds = CGRect(x: 0, y: 0, width: ceil(size.width) + 12, height: ceil(size.height) + 6)
        textLayer.frame = CGRect(x: 6, y: 3, width: ceil(size.width), height: ceil(size.height))
    }
}

final class OverlayView: NSView {
    private let snapshot: DisplaySnapshot
    private let windowInfos: [WindowInfo]
    fileprivate weak var session: SelectionSession?

    var mode: SelectionMode {
        didSet {
            selection = nil
            window?.invalidateCursorRects(for: self)
            refresh()
        }
    }
    var spaceHeld = false
    private(set) var isDragging = false

    private var mouse: CGPoint?
    private var anchor = CGPoint.zero
    private var lastDragPoint = CGPoint.zero
    private var selection: CGRect?
    private var hoveredWindow: WindowInfo?

    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    /// Dark line with white dashes on top, so the crosshair shows on any background.
    private let crosshairLayer = CAShapeLayer()
    private let crosshairDashes = CAShapeLayer()
    private let loupe = CALayer()
    private let loupeImage = CALayer()
    private let loupeReticle = CAShapeLayer()
    private let loupeRing = CAShapeLayer()
    /// Shows the cursor position, or the selection size while dragging.
    private let infoLabel: LabelLayer

    private static let loupeSize: CGFloat = 120
    /// The loupe shows a square of (2 * radius + 1) pixels around the cursor.
    private static let loupePixelRadius = 7

    init(snapshot: DisplaySnapshot, windowInfos: [WindowInfo], mode: SelectionMode) {
        self.snapshot = snapshot
        self.windowInfos = windowInfos
        self.mode = mode
        let backing = snapshot.screen.backingScaleFactor
        infoLabel = LabelLayer(contentsScale: backing)
        super.init(frame: CGRect(origin: .zero, size: snapshot.screen.frame.size))
        wantsLayer = true
        setUpLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setUpLayers() {
        guard let root = layer else { return }
        root.contents = snapshot.image
        root.contentsGravity = .resize

        dimLayer.fillRule = .evenOdd
        borderLayer.fillColor = nil
        borderLayer.lineWidth = 1
        crosshairLayer.fillColor = nil
        crosshairLayer.strokeColor = NSColor.black.withAlphaComponent(0.55).cgColor
        crosshairLayer.lineWidth = 1
        crosshairDashes.fillColor = nil
        crosshairDashes.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        crosshairDashes.lineWidth = 1
        crosshairDashes.lineDashPattern = [4, 4]

        let size = Self.loupeSize
        loupe.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        loupe.cornerRadius = size / 2
        loupe.masksToBounds = true
        loupe.borderColor = NSColor.white.cgColor
        loupe.borderWidth = 2
        loupe.backgroundColor = NSColor.black.cgColor
        loupeImage.frame = loupe.bounds
        loupeImage.magnificationFilter = .nearest
        loupeImage.contentsGravity = .resize
        let cell = size / CGFloat(Self.loupePixelRadius * 2 + 1)
        // The reticle and the outer ring pair a dark and a light stroke for contrast on any content.
        let cellRect = CGRect(x: (size - cell) / 2, y: (size - cell) / 2, width: cell, height: cell)
        let reticleInner = CAShapeLayer()
        reticleInner.path = CGPath(rect: cellRect.insetBy(dx: 1, dy: 1), transform: nil)
        reticleInner.fillColor = nil
        reticleInner.strokeColor = NSColor.white.cgColor
        reticleInner.lineWidth = 1
        loupeReticle.frame = loupe.bounds
        loupeReticle.path = CGPath(rect: cellRect, transform: nil)
        loupeReticle.fillColor = nil
        loupeReticle.strokeColor = NSColor.black.withAlphaComponent(0.7).cgColor
        loupeReticle.lineWidth = 1
        loupeReticle.addSublayer(reticleInner)
        loupe.addSublayer(loupeImage)
        loupe.addSublayer(loupeReticle)
        loupeRing.bounds = loupe.bounds
        loupeRing.path = CGPath(ellipseIn: loupe.bounds.insetBy(dx: -0.5, dy: -0.5), transform: nil)
        loupeRing.fillColor = nil
        loupeRing.strokeColor = NSColor.black.withAlphaComponent(0.5).cgColor
        loupeRing.lineWidth = 1

        for sublayer in [dimLayer, borderLayer, crosshairLayer, crosshairDashes, loupe, loupeRing, infoLabel] {
            sublayer.isHidden = true
            root.addSublayer(sublayer)
        }
    }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == .area ? .crosshair : .pointingHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    fileprivate func mouseArrived(at point: CGPoint) {
        mouse = point
        refresh()
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        mouseArrived(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        mouse = nil
        refresh()
    }

    override func mouseMoved(with event: NSEvent) {
        mouseArrived(at: convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        session?.finish(.cancelled)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouse = point
        guard mode == .area else { return }
        isDragging = true
        anchor = point
        lastDragPoint = point
        selection = CGRect(origin: point, size: .zero)
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        mouse = point
        if spaceHeld {
            anchor.x += point.x - lastDragPoint.x
            anchor.y += point.y - lastDragPoint.y
        }
        lastDragPoint = point
        let flags = event.modifierFlags
        selection = Geometry.rect(from: anchor, to: point,
                                  square: flags.contains(.shift),
                                  fromCenter: flags.contains(.option)).intersection(bounds)
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        if mode == .window {
            if let hoveredWindow {
                session?.finish(.window(snapshot: snapshot, window: hoveredWindow))
            }
            return
        }
        guard isDragging else { return }
        isDragging = false
        spaceHeld = false
        if let rect = selection?.integral, rect.width >= 4, rect.height >= 4 {
            session?.finish(.area(snapshot: snapshot, rect: rect))
        } else {
            selection = nil
            refresh()
        }
    }

    // MARK: Drawing

    private func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        hoveredWindow = nil
        var highlight: CGRect?
        if mode == .window, let mouse {
            let global = Geometry.globalPoint(forViewPoint: mouse, displayBounds: snapshot.displayBounds)
            hoveredWindow = windowInfos.first { $0.frame.contains(global) }
            if let hoveredWindow {
                highlight = Geometry.viewRect(forGlobalRect: hoveredWindow.frame,
                                              displayBounds: snapshot.displayBounds).intersection(bounds)
            }
        } else if mode == .area {
            highlight = selection
        }

        // Dim everything outside the highlighted rect.
        if let highlight {
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(highlight)
            dimLayer.path = path
            dimLayer.fillColor = NSColor.black.withAlphaComponent(0.4).cgColor
            dimLayer.isHidden = false
            borderLayer.path = CGPath(rect: highlight, transform: nil)
            borderLayer.strokeColor = (mode == .window ? NSColor.controlAccentColor : NSColor.white).cgColor
            borderLayer.lineWidth = mode == .window ? 3 : 1
            borderLayer.isHidden = false
        } else {
            dimLayer.isHidden = true
            borderLayer.isHidden = true
        }

        let showsCursorAids = mode == .area && mouse != nil
        crosshairLayer.isHidden = !(showsCursorAids && !isDragging)
        crosshairDashes.isHidden = crosshairLayer.isHidden
        if let mouse, !crosshairLayer.isHidden {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: mouse.y))
            path.addLine(to: CGPoint(x: bounds.width, y: mouse.y))
            path.move(to: CGPoint(x: mouse.x, y: 0))
            path.addLine(to: CGPoint(x: mouse.x, y: bounds.height))
            crosshairLayer.path = path
            crosshairDashes.path = path
        }

        updateCursorAids(visible: showsCursorAids)
    }

    /// Centers a box of `size` below-right of `point`, flipping sides to stay on screen.
    private func clampedCenter(for size: CGSize, near point: CGPoint, offset: CGSize) -> CGPoint {
        var x = point.x + offset.width + size.width / 2
        var y = point.y - offset.height - size.height / 2
        if x + size.width / 2 > bounds.maxX { x = point.x - offset.width - size.width / 2 }
        if y - size.height / 2 < bounds.minY { y = point.y + offset.height + size.height / 2 }
        return CGPoint(x: x, y: y)
    }

    /// Places the loupe (when enabled) and the info label next to the cursor.
    private func updateCursorAids(visible: Bool) {
        guard visible, let mouse else {
            [loupe, loupeRing, infoLabel].forEach { $0.isHidden = true }
            return
        }
        if let selection, isDragging {
            infoLabel.setText("\(Int(selection.width)) × \(Int(selection.height))")
        } else {
            infoLabel.setText("\(Int(mouse.x)), \(Int(bounds.height - mouse.y))")
        }
        infoLabel.isHidden = false

        guard Prefs.showMagnifier else {
            loupe.isHidden = true
            loupeRing.isHidden = true
            infoLabel.position = clampedCenter(for: infoLabel.bounds.size, near: mouse,
                                               offset: CGSize(width: 16, height: 16))
            return
        }
        let scale = snapshot.scale
        let pixel = CGPoint(x: floor(mouse.x * scale), y: floor((bounds.height - mouse.y) * scale))
        loupeImage.contents = Self.magnifiedPatch(of: snapshot.image, around: pixel, radius: Self.loupePixelRadius)

        let size = Self.loupeSize
        let labelHeight = infoLabel.bounds.height
        let center = clampedCenter(for: CGSize(width: size, height: size + labelHeight + 6), near: mouse,
                                   offset: CGSize(width: 22, height: 22))
        loupe.position = CGPoint(x: center.x, y: center.y + (labelHeight + 6) / 2)
        loupeRing.position = loupe.position
        infoLabel.position = CGPoint(x: center.x, y: center.y - size / 2 - 3)
        loupe.isHidden = false
        loupeRing.isHidden = false
    }

    /// Renders the pixels around `center` (top-left origin) into a tiny bitmap; areas off the image stay black.
    static func magnifiedPatch(of image: CGImage, around center: CGPoint, radius: Int) -> CGImage? {
        let side = radius * 2 + 1
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        let source = CGRect(x: center.x - CGFloat(radius), y: center.y - CGFloat(radius),
                            width: CGFloat(side), height: CGFloat(side))
        let clipped = source.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !clipped.isEmpty, let patch = image.cropping(to: clipped) else { return context.makeImage() }
        let dx = clipped.minX - source.minX
        let dy = clipped.minY - source.minY
        context.draw(patch, in: CGRect(x: dx, y: CGFloat(side) - dy - clipped.height,
                                       width: clipped.width, height: clipped.height))
        return context.makeImage()
    }
}
