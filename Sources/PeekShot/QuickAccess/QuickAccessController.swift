import AppKit
import CoreImage

/// Stacks thumbnail cards of fresh captures in a screen corner.
@MainActor
final class QuickAccessController {
    static let shared = QuickAccessController()

    private var cards: [QuickAccessPanel] = []
    static let cardSize = CGSize(width: 208, height: 148)
    private static let sideMargin: CGFloat = 40
    private static let bottomMargin: CGFloat = 22
    private static let spacing: CGFloat = 12
    private static let maxCards = 5
    /// How far a card travels sideways while it fades in or out.
    private static let slide: CGFloat = 48

    var windowNumbers: Set<Int> { Set(cards.map(\.windowNumber)) }

    private var slideOffset: CGFloat { Prefs.overlayPosition == .left ? -Self.slide : Self.slide }

    func show(_ item: CaptureItem, on screen: NSScreen) {
        let panel = QuickAccessPanel(item: item, screen: screen, size: Self.cardSize)
        panel.cardView.onClose = { [weak self, weak panel] in
            if let panel { self?.dismiss(panel) }
        }
        cards.insert(panel, at: 0)
        while cards.count > Self.maxCards, let oldest = cards.last {
            dismiss(oldest, animated: false)
        }
        layout(animated: true, entering: panel)

        let seconds = Prefs.overlayAutoClose
        if seconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self, weak panel] in
                if let panel, !panel.cardView.isHovering { self?.dismiss(panel) }
            }
        }
    }

    private func dismiss(_ panel: QuickAccessPanel, animated: Bool = true) {
        guard let index = cards.firstIndex(where: { $0 === panel }) else { return }
        cards.remove(at: index)
        if animated {
            // Slide back out towards the screen edge it came from.
            let target = panel.frame.offsetBy(dx: slideOffset, dy: 0)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        } else {
            panel.orderOut(nil)
        }
        layout(animated: animated, entering: nil)
    }

    /// Height to keep clear at the bottom of the screen: the Dock, also while it is auto-hidden,
    /// so a card never sits where the Dock slides in.
    static func dockInset(on screen: NSScreen) -> CGFloat {
        let visibleInset = screen.visibleFrame.minY - screen.frame.minY
        if visibleInset > 0 { return visibleInset }
        guard let dock = UserDefaults(suiteName: "com.apple.dock"), dock.bool(forKey: "autohide"),
              (dock.string(forKey: "orientation") ?? "bottom") == "bottom" else { return 0 }
        let tileSize = dock.double(forKey: "tilesize")
        return CGFloat(tileSize > 0 ? tileSize : 48) + 26
    }

    /// Newest card sits at the bottom of each screen's stack; older ones move up.
    private func layout(animated: Bool, entering: QuickAccessPanel?) {
        var countByScreen: [CGDirectDisplayID: Int] = [:]
        for panel in cards {
            let screen = panel.targetScreen
            let index = countByScreen[screen.displayID, default: 0]
            countByScreen[screen.displayID] = index + 1
            let visible = screen.visibleFrame
            let size = Self.cardSize
            let x = Prefs.overlayPosition == .left
                ? visible.minX + Self.sideMargin
                : visible.maxX - Self.sideMargin - size.width
            let y = screen.frame.minY + Self.dockInset(on: screen) + Self.bottomMargin
                + CGFloat(index) * (size.height + Self.spacing)
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)

            if panel === entering {
                panel.setFrame(frame.offsetBy(dx: slideOffset, dy: 0), display: true)
                panel.alphaValue = 0
                panel.orderFrontRegardless()
            }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.26
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(frame, display: true)
                    panel.animator().alphaValue = 1
                }
            } else {
                panel.setFrame(frame, display: true)
            }
        }
    }
}

final class QuickAccessPanel: NSPanel {
    let cardView: QuickAccessCardView
    let targetScreen: NSScreen

    init(item: CaptureItem, screen: NSScreen, size: CGSize) {
        cardView = QuickAccessCardView(item: item, frame: CGRect(origin: .zero, size: size),
                                       backingScale: screen.backingScaleFactor)
        targetScreen = screen
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = cardView
    }
}

/// A light round or capsule button that brightens under the pointer, even while the app is inactive.
private final class CardButton: NSButton {
    private static let restingColor = NSColor(white: 1, alpha: 0.86).cgColor
    private static let hoverColor = NSColor(white: 1, alpha: 1).cgColor

    init(frame: CGRect, target: AnyObject, action: Selector, tip: String) {
        super.init(frame: frame)
        self.target = target
        self.action = action
        toolTip = tip
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = Self.restingColor
        layer?.cornerRadius = frame.height / 2
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = Self.hoverColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = Self.restingColor }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class QuickAccessCardView: NSView, NSDraggingSource {
    let item: CaptureItem
    var onClose: (() -> Void)?
    private(set) var isHovering = false

    /// Blurred, dimmed copy of the thumbnail plus the buttons; shown while the pointer is over the card.
    private let controls = NSView()
    private var mouseDownLocation: CGPoint?

    private static let glyphColor = NSColor(white: 0, alpha: 0.82)
    private static let ciContext = CIContext()

    init(item: CaptureItem, frame: CGRect, backingScale: CGFloat = 2) {
        self.item = item
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor

        let thumbnail = Self.thumbnail(of: item, size: frame.size, scale: backingScale)
        layer?.contents = thumbnail
        setUpControls(backdrop: thumbnail.flatMap { Self.blurredBackdrop(of: $0, radius: 9 * backingScale) })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Renders the capture into a card-sized bitmap: small captures stay at their natural size and
    /// centered, larger ones fill the card.
    static func thumbnail(of item: CaptureItem, size: CGSize, scale: CGFloat) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(CGColor(gray: 0.14, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        var drawSize = item.pointSize
        if drawSize.width > size.width || drawSize.height > size.height {
            let fill = max(size.width / drawSize.width, size.height / drawSize.height)
            drawSize = CGSize(width: drawSize.width * fill, height: drawSize.height * fill)
        }
        ctx.interpolationQuality = .high
        ctx.draw(item.image, in: CGRect(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2,
                                        width: drawSize.width, height: drawSize.height))
        return ctx.makeImage()
    }

    /// Blurs and darkens the thumbnail so the light buttons read on any screenshot.
    static func blurredBackdrop(of image: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        guard let blurred = ciContext.createCGImage(output, from: input.extent),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.draw(blurred, in: bounds)
        // Dimmed in sRGB so even a white page ends up as a mid-dark gray behind the light buttons.
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.58))
        ctx.fill(bounds)
        return ctx.makeImage()
    }

    private func setUpControls(backdrop: CGImage?) {
        controls.frame = bounds
        controls.wantsLayer = true
        controls.layer?.contents = backdrop
        controls.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.75).cgColor
        controls.isHidden = true
        addSubview(controls)

        // Capsules hug their label; the pair is centered on the card.
        let copy = pillButton("Copy", action: #selector(copyImage))
        let save = pillButton("Save", action: #selector(saveImage))
        let pillHeight: CGFloat = 27, gap: CGFloat = 10
        copy.frame.origin = CGPoint(x: (bounds.width - copy.frame.width) / 2, y: bounds.midY + gap / 2)
        save.frame.origin = CGPoint(x: (bounds.width - save.frame.width) / 2, y: bounds.midY - gap / 2 - pillHeight)

        let inset: CGFloat = 6, side: CGFloat = 22
        let left = inset, right = bounds.width - inset - side
        let top = bounds.height - inset - side, bottom = inset
        let buttons = [
            copy, save,
            iconButton("xmark", tip: "Close", action: #selector(closeCard), origin: CGPoint(x: left, y: top), side: side),
            iconButton("pin.fill", tip: "Pin to screen", action: #selector(pinImage), origin: CGPoint(x: right, y: top), side: side),
            iconButton("pencil", tip: "Annotate", action: #selector(editImage), origin: CGPoint(x: left, y: bottom), side: side),
            iconButton("ellipsis", tip: "More", action: #selector(showMenu(_:)), origin: CGPoint(x: right, y: bottom), side: side),
        ]
        buttons.forEach(controls.addSubview)
    }

    private func pillButton(_ title: String, action: Selector) -> NSButton {
        let label = NSAttributedString(string: title, attributes: [
            .foregroundColor: Self.glyphColor,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        ])
        let width = ceil(label.size().width) + 24
        let button = CardButton(frame: CGRect(x: 0, y: 0, width: width, height: 27), target: self, action: action, tip: title)
        button.attributedTitle = label
        return button
    }

    private func iconButton(_ symbol: String, tip: String, action: Selector, origin: CGPoint, side: CGFloat) -> NSButton {
        let button = CardButton(frame: CGRect(origin: origin, size: CGSize(width: side, height: side)),
                                target: self, action: action, tip: tip)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        button.imagePosition = .imageOnly
        button.contentTintColor = Self.glyphColor
        return button
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        controls.alphaValue = 0
        controls.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            controls.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        controls.isHidden = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Actions

    @objc private func copyImage() {
        CaptureActions.copy(item)
        onClose?()
    }

    @objc private func saveImage() {
        if CaptureActions.save(item) != nil { onClose?() }
    }

    @objc private func saveImageAs() {
        CaptureActions.saveAs(item)
    }

    @objc private func editImage() {
        CaptureActions.edit(item)
        onClose?()
    }

    @objc private func pinImage() {
        CaptureActions.pin(item)
        onClose?()
    }

    @objc private func revealImage() {
        CaptureActions.revealInFinder(item)
    }

    @objc private func closeCard() {
        onClose?()
    }

    @objc private func showMenu(_ sender: NSView) {
        makeMenu().popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let entries: [(String, String, Selector)] = [
            ("Copy", "doc.on.doc", #selector(copyImage)), ("Save", "square.and.arrow.down", #selector(saveImage)),
            ("Save As…", "square.and.arrow.down.on.square", #selector(saveImageAs)),
            ("Annotate", "pencil", #selector(editImage)), ("Pin to Screen", "pin", #selector(pinImage)),
            ("Show in Finder", "folder", #selector(revealImage)), ("Close", "xmark", #selector(closeCard)),
        ]
        for (title, symbol, action) in entries {
            let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return menu
    }

    // MARK: Drag out

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        if event.clickCount == 2 { editImage() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation, let url = item.fileURL else { return }
        let location = event.locationInWindow
        guard hypot(location.x - start.x, location.y - start.y) > 4 else { return }
        mouseDownLocation = nil
        let draggingItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        draggingItem.setDraggingFrame(bounds, contents: item.nsImage)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] { onClose?() }
    }
}
