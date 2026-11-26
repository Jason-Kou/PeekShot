import AppKit

/// A screenshot floating above all windows.
@MainActor
final class PinWindowController: NSObject {
    private static var pins: [PinWindowController] = []

    static func pin(_ item: CaptureItem) {
        pins.append(PinWindowController(item: item))
    }

    private let item: CaptureItem
    private let panel: PinPanel

    private init(item: CaptureItem) {
        self.item = item
        let visible = NSScreen.underMouse.visibleFrame
        var size = item.pointSize
        let fit = min(1, visible.width * 0.7 / size.width, visible.height * 0.7 / size.height)
        size = CGSize(width: size.width * fit, height: size.height * fit)
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                           width: size.width, height: size.height)

        panel = PinPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init()

        let view = PinView(item: item, frame: CGRect(origin: .zero, size: size))
        view.controller = self
        panel.contentView = view
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        Self.pins.removeAll { $0 === self }
    }

    /// Resizes around the center, keeping the aspect ratio.
    func zoom(by factor: CGFloat) {
        let frame = panel.frame
        let aspect = item.pointSize.height / item.pointSize.width
        let maxWidth = (panel.screen ?? NSScreen.underMouse).frame.width
        let width = min(max(frame.width * factor, 60), maxWidth)
        let size = CGSize(width: width, height: width * aspect)
        panel.setFrame(CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
    }

    func setOpacity(_ value: CGFloat) {
        panel.alphaValue = min(max(value, 0.2), 1)
    }

    var opacity: CGFloat { panel.alphaValue }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let entries: [(String, Selector)] = [
            ("Copy", #selector(copyImage)), ("Save", #selector(saveImage)), ("Annotate", #selector(editImage)),
        ]
        for (title, action) in entries {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for percent in [100, 75, 50, 25] {
            let entry = NSMenuItem(title: "\(percent)%", action: #selector(pickOpacity(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = percent
            entry.state = Int((opacity * 100).rounded()) == percent ? .on : .off
            opacityMenu.addItem(entry)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)
        let reset = NSMenuItem(title: "Actual Size", action: #selector(resetSize), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close", action: #selector(closeFromMenu), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func copyImage() { CaptureActions.copy(item) }
    @objc private func saveImage() { CaptureActions.save(item) }
    @objc private func closeFromMenu() { close() }
    @objc private func pickOpacity(_ sender: NSMenuItem) { setOpacity(CGFloat(sender.tag) / 100) }

    @objc private func editImage() {
        CaptureActions.edit(item)
        close()
    }

    @objc private func resetSize() {
        zoom(by: item.pointSize.width / panel.frame.width)
    }
}

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class PinView: NSView {
    weak var controller: PinWindowController?
    private let closeButton: NSButton

    init(item: CaptureItem, frame: CGRect) {
        let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold)) ?? NSImage()
        closeButton = NSButton(image: image, target: nil, action: nil)
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = item.image
        layer?.contentsGravity = .resize
        layer?.cornerRadius = 4
        layer?.masksToBounds = true

        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        closeButton.layer?.cornerRadius = 11
        closeButton.frame = CGRect(x: 6, y: frame.height - 28, width: 22, height: 22)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        closeButton.target = self
        closeButton.action = #selector(closePin)
        closeButton.isHidden = true
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    @objc private func closePin() { controller?.close() }

    /// Scroll to zoom; hold Option to change opacity instead.
    override func scrollWheel(with event: NSEvent) {
        guard let controller, event.scrollingDeltaY != 0 else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.004 : event.scrollingDeltaY * 0.04
        if event.modifierFlags.contains(.option) {
            controller.setOpacity(controller.opacity + delta)
        } else {
            controller.zoom(by: 1 + delta)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { controller?.makeMenu() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // escape
            controller?.close()
        } else {
            super.keyDown(with: event)
        }
    }
}
