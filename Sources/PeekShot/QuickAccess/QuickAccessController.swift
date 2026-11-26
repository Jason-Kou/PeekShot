import AppKit

/// Stacks thumbnail cards of fresh captures in a screen corner.
@MainActor
final class QuickAccessController {
    static let shared = QuickAccessController()

    private var cards: [QuickAccessPanel] = []
    private static let cardSize = CGSize(width: 216, height: 136)
    private static let margin: CGFloat = 20
    private static let spacing: CGFloat = 12
    private static let maxCards = 5

    var windowNumbers: Set<Int> { Set(cards.map(\.windowNumber)) }

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
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        } else {
            panel.orderOut(nil)
        }
        layout(animated: animated, entering: nil)
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
                ? visible.minX + Self.margin
                : visible.maxX - Self.margin - size.width
            let y = visible.minY + Self.margin + CGFloat(index) * (size.height + Self.spacing)
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)

            if panel === entering {
                let offset: CGFloat = Prefs.overlayPosition == .left ? -40 : 40
                panel.setFrame(frame.offsetBy(dx: offset, dy: 0), display: true)
                panel.alphaValue = 0
                panel.orderFrontRegardless()
            }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
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
        cardView = QuickAccessCardView(item: item, frame: CGRect(origin: .zero, size: size))
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

final class QuickAccessCardView: NSView, NSDraggingSource {
    let item: CaptureItem
    var onClose: (() -> Void)?
    private(set) var isHovering = false

    private let controls = NSView()
    private var mouseDownLocation: CGPoint?

    init(item: CaptureItem, frame: CGRect) {
        self.item = item
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        layer?.contents = item.image
        // Small captures stay crisp and centered; large ones fill the card.
        let fits = item.pointSize.width <= frame.width && item.pointSize.height <= frame.height
        layer?.contentsGravity = fits ? .center : .resizeAspectFill
        layer?.contentsScale = item.scale
        setUpControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setUpControls() {
        controls.frame = bounds
        controls.wantsLayer = true
        controls.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        controls.isHidden = true
        addSubview(controls)

        let copy = pillButton("复制", action: #selector(copyImage))
        let save = pillButton("保存", action: #selector(saveImage))
        let pillWidth: CGFloat = 84
        copy.frame = CGRect(x: (bounds.width - pillWidth) / 2, y: bounds.midY + 3, width: pillWidth, height: 26)
        save.frame = CGRect(x: (bounds.width - pillWidth) / 2, y: bounds.midY - 29, width: pillWidth, height: 26)

        let inset: CGFloat = 8, side: CGFloat = 24
        let close = iconButton("xmark", tip: "关闭", action: #selector(closeCard))
        close.frame = CGRect(x: inset, y: bounds.height - inset - side, width: side, height: side)
        let pin = iconButton("pin.fill", tip: "贴图到屏幕", action: #selector(pinImage))
        pin.frame = CGRect(x: bounds.width - inset - side, y: bounds.height - inset - side, width: side, height: side)
        let edit = iconButton("pencil", tip: "标注", action: #selector(editImage))
        edit.frame = CGRect(x: inset, y: inset, width: side, height: side)
        let more = iconButton("ellipsis", tip: "更多", action: #selector(showMenu(_:)))
        more.frame = CGRect(x: bounds.width - inset - side, y: inset, width: side, height: side)

        [copy, save, close, pin, edit, more].forEach(controls.addSubview)
    }

    private func pillButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        button.layer?.cornerRadius = 13
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.black,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ])
        return button
    }

    private func iconButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold)) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        button.layer?.cornerRadius = 12
        button.toolTip = tip
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
        controls.isHidden = false
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
        let entries: [(String, Selector)] = [
            ("复制", #selector(copyImage)), ("保存", #selector(saveImage)), ("另存为…", #selector(saveImageAs)),
            ("标注", #selector(editImage)), ("贴图到屏幕", #selector(pinImage)),
            ("在访达中显示", #selector(revealImage)), ("关闭", #selector(closeCard)),
        ]
        for (title, action) in entries {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
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
