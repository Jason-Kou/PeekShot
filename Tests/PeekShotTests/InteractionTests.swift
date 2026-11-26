import SwiftUI
import XCTest
@testable import PeekShot

/// Drives the real views with synthetic mouse events in off-screen windows.
/// Set PEEKSHOT_SNAPSHOT_DIR (TEST_RUNNER_PEEKSHOT_SNAPSHOT_DIR for xcodebuild) to also write PNGs for a visual check.
@MainActor
final class InteractionTests: XCTestCase {
    private func testPattern(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Stripes give blur and pixelate something to chew on.
        ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.3, blue: 0.4, alpha: 1))
        for x in stride(from: 0, to: width, by: 24) {
            ctx.fill(CGRect(x: x, y: height / 3, width: 8, height: height / 3))
        }
        // Red marks the top-left corner, blue the bottom-right one.
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height - height / 8, width: width / 8, height: height / 8))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: width - width / 8, y: 0, width: width / 8, height: height / 8))
        return ctx.makeImage()!
    }

    private func save(_ image: CGImage?, _ name: String) {
        guard let image, let directory = ProcessInfo.processInfo.environment["PEEKSHOT_SNAPSHOT_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        ImageCodec.write(image, scale: 1, format: .png, to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    private func layerSnapshot(of view: NSView) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        guard let layer = view.layer,
              let ctx = CGContext(data: nil, width: Int(view.bounds.width), height: Int(view.bounds.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    private func viewSnapshot(of view: NSView) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    private func host(_ view: NSView, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = CGRect(origin: .zero, size: size)
        window.contentView = view
        return window
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView, clicks: Int = 1,
                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
                           windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                           clickCount: clicks, pressure: 1)!
    }

    private func drag(on view: NSView, from a: CGPoint, to b: CGPoint, flags: NSEvent.ModifierFlags = []) {
        view.mouseDown(with: mouse(.leftMouseDown, at: a, in: view))
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        view.mouseDragged(with: mouse(.leftMouseDragged, at: mid, in: view, flags: flags))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: b, in: view, flags: flags))
        view.mouseUp(with: mouse(.leftMouseUp, at: b, in: view))
    }

    // MARK: Selection overlay

    func testOverlayShowsCrosshairThenSelection() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let size = screen.frame.size
        let snapshot = DisplaySnapshot(screen: screen, displayID: screen.displayID,
                                       image: testPattern(width: Int(size.width) * 2, height: Int(size.height) * 2))
        XCTAssertEqual(snapshot.scale, 2, accuracy: 0.01)
        let view = OverlayView(snapshot: snapshot, windowInfos: [], mode: .area)
        let window = host(view, size: size)
        defer { window.close() }

        view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 300, y: size.height - 200), in: view))
        save(layerSnapshot(of: view), "overlay-idle")

        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 300, y: size.height - 200), in: view))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 760, y: size.height - 520), in: view))
        XCTAssertTrue(view.isDragging)
        save(layerSnapshot(of: view), "overlay-dragging")
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 760, y: size.height - 520), in: view))
        XCTAssertFalse(view.isDragging)
    }

    func testOverlayHighlightsWindowUnderCursor() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let size = screen.frame.size
        let snapshot = DisplaySnapshot(screen: screen, displayID: screen.displayID,
                                       image: testPattern(width: Int(size.width), height: Int(size.height)))
        let bounds = snapshot.displayBounds
        // A fake window 100 pt from the display's top-left corner.
        let info = WindowInfo(id: 1, frame: CGRect(x: bounds.minX + 100, y: bounds.minY + 100, width: 500, height: 300))
        let view = OverlayView(snapshot: snapshot, windowInfos: [info], mode: .window)
        let window = host(view, size: size)
        defer { window.close() }
        view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 300, y: size.height - 250), in: view))
        save(layerSnapshot(of: view), "overlay-window-mode")
    }

    // MARK: Live selection session

    private var visibleOverlayWindows: [NSWindow] {
        NSApp.windows.filter { $0.level == .screenSaver && $0.isVisible }
    }

    /// Runs the real overlay windows on screen. Uses a live capture when the test host has screen
    /// recording permission and a test pattern otherwise.
    func testLiveSelectionSessionSelectsAndCancels() async throws {
        let snapshots: [DisplaySnapshot]
        if ScreenCapturer.hasPermission {
            snapshots = try await ScreenCapturer.snapshotAllDisplays()
        } else {
            snapshots = NSScreen.screens.map { screen in
                DisplaySnapshot(screen: screen, displayID: screen.displayID,
                                image: testPattern(width: Int(screen.frame.width), height: Int(screen.frame.height)))
            }
        }
        XCTAssertEqual(snapshots.count, NSScreen.screens.count)

        // Drag out an area with real window-level mouse events.
        var outcome: SelectionOutcome?
        var session: SelectionSession? = SelectionSession(snapshots: snapshots, windowInfos: [], mode: .area)
        session?.begin { outcome = $0 }
        XCTAssertEqual(visibleOverlayWindows.count, snapshots.count)
        let window = try XCTUnwrap(visibleOverlayWindows.first)
        func send(_ type: NSEvent.EventType, _ point: CGPoint) {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                clickCount: 1, pressure: 1)!)
        }
        send(.leftMouseDown, CGPoint(x: 200, y: 300))
        send(.leftMouseDragged, CGPoint(x: 350, y: 400))
        send(.leftMouseDragged, CGPoint(x: 500, y: 500))
        send(.leftMouseUp, CGPoint(x: 500, y: 500))
        guard case let .area(snapshot, rect)? = outcome else {
            return XCTFail("expected an area, got \(String(describing: outcome))")
        }
        XCTAssertEqual(rect, CGRect(x: 200, y: 300, width: 300, height: 200))
        XCTAssertEqual(snapshot.screen.frame, window.frame)
        XCTAssertTrue(visibleOverlayWindows.isEmpty, "overlays must be gone after a selection")

        // Escape cancels through the key monitor.
        outcome = nil
        session = SelectionSession(snapshots: snapshots, windowInfos: [], mode: .area)
        session?.begin { outcome = $0 }
        let overlay = try XCTUnwrap(visibleOverlayWindows.first)
        NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: overlay.windowNumber, context: nil, characters: "\u{1b}",
                                         charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!,
                        atStart: true)
        for _ in 0..<20 where outcome == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard case .cancelled? = outcome else {
            return XCTFail("expected cancel, got \(String(describing: outcome))")
        }
        XCTAssertTrue(visibleOverlayWindows.isEmpty)
    }

    // MARK: Editor canvas

    func testCanvasDrawsEveryToolAndUndoes() throws {
        let state = EditorState()
        let canvas = CanvasView(image: testPattern(width: 1600, height: 1000), scale: 2, state: state)
        XCTAssertEqual(canvas.imagePointSize, CGSize(width: 800, height: 500))
        let window = host(canvas, size: canvas.imagePointSize)
        defer { window.close() }

        state.tool = .arrow
        drag(on: canvas, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 220, y: 140))
        state.tool = .rectangle
        drag(on: canvas, from: CGPoint(x: 260, y: 40), to: CGPoint(x: 420, y: 140))
        state.tool = .ellipse
        state.color = EditorState.palette[4]
        drag(on: canvas, from: CGPoint(x: 460, y: 40), to: CGPoint(x: 600, y: 140))
        state.tool = .line
        drag(on: canvas, from: CGPoint(x: 640, y: 50), to: CGPoint(x: 760, y: 130))
        state.tool = .pencil
        state.color = EditorState.palette[3]
        drag(on: canvas, from: CGPoint(x: 60, y: 420), to: CGPoint(x: 200, y: 460))
        state.tool = .highlighter
        state.color = EditorState.palette[2]
        drag(on: canvas, from: CGPoint(x: 240, y: 440), to: CGPoint(x: 420, y: 440))
        state.tool = .pixelate
        drag(on: canvas, from: CGPoint(x: 40, y: 190), to: CGPoint(x: 240, y: 310))
        state.tool = .blur
        drag(on: canvas, from: CGPoint(x: 280, y: 190), to: CGPoint(x: 480, y: 310))
        state.tool = .counter
        state.color = EditorState.palette[0]
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 540, y: 400), in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 540, y: 400), in: canvas))
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 600, y: 400), in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 600, y: 400), in: canvas))

        // Type a text annotation through the inline editor.
        state.tool = .text
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 560, y: 250), in: canvas))
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        editor.string = "Hello 标注"
        canvas.commitText()
        XCTAssertTrue(canvas.subviews.isEmpty)

        XCTAssertEqual(canvas.annotations.count, 11)
        XCTAssertEqual(canvas.annotations.filter { $0.kind == .counter }.map(\.number), [1, 2])
        XCTAssertEqual(canvas.annotations.last?.text, "Hello 标注")
        XCTAssertTrue(canvas.hasUnsavedChanges)
        save(viewSnapshot(of: canvas), "canvas-live")
        let flat = canvas.renderedImage()
        XCTAssertEqual(flat.width, 1600)
        save(flat, "canvas-flattened")

        canvas.undo()
        XCTAssertEqual(canvas.annotations.count, 10)
        canvas.redo()
        XCTAssertEqual(canvas.annotations.count, 11)
        XCTAssertTrue(state.canUndo)
    }

    func testSelectedShapeCanBeMovedResizedAndDeleted() {
        let state = EditorState()
        let canvas = CanvasView(image: testPattern(width: 400, height: 300), scale: 1, state: state)
        let window = host(canvas, size: canvas.imagePointSize)
        defer { window.close() }

        state.tool = .rectangle
        drag(on: canvas, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 120))
        XCTAssertEqual(canvas.annotations[0].rect, CGRect(x: 50, y: 50, width: 100, height: 70))

        // Dragging the border moves the freshly drawn (selected) shape even with the drawing tool active.
        drag(on: canvas, from: CGPoint(x: 100, y: 50), to: CGPoint(x: 120, y: 80))
        XCTAssertEqual(canvas.annotations.count, 1)
        XCTAssertEqual(canvas.annotations[0].rect, CGRect(x: 70, y: 80, width: 100, height: 70))

        // Dragging the bottom-right handle resizes it.
        drag(on: canvas, from: CGPoint(x: 170, y: 150), to: CGPoint(x: 200, y: 200))
        XCTAssertEqual(canvas.annotations[0].rect, CGRect(x: 70, y: 80, width: 130, height: 120))

        // A style change applies to the selection.
        canvas.applyStyle(color: EditorState.palette[4], size: 8, filled: true)
        XCTAssertTrue(canvas.annotations[0].filled)
        XCTAssertEqual(canvas.annotations[0].size, 8)

        canvas.deleteSelection()
        XCTAssertTrue(canvas.annotations.isEmpty)
        canvas.undo()
        XCTAssertEqual(canvas.annotations.count, 1)
    }

    func testCropShrinksImageAndShiftsAnnotations() {
        let state = EditorState()
        let canvas = CanvasView(image: testPattern(width: 800, height: 600), scale: 2, state: state)
        let window = host(canvas, size: canvas.imagePointSize)
        defer { window.close() }

        state.tool = .line
        drag(on: canvas, from: CGPoint(x: 120, y: 110), to: CGPoint(x: 200, y: 110))
        state.tool = .crop
        drag(on: canvas, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))

        XCTAssertEqual(canvas.baseImage.width, 400)
        XCTAssertEqual(canvas.baseImage.height, 300)
        XCTAssertEqual(canvas.frame.size, CGSize(width: 200, height: 150))
        XCTAssertEqual(canvas.annotations[0].start, CGPoint(x: 20, y: 10))

        canvas.undo()
        XCTAssertEqual(canvas.baseImage.width, 800)
        XCTAssertEqual(canvas.annotations[0].start, CGPoint(x: 120, y: 110))
    }

    // MARK: Windows

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    func testEditorWindowFitsLargeImageAndCloses() throws {
        // 1600 x 1000 pt: larger than the editor can show at 100 % on a laptop display.
        let item = CaptureItem(image: testPattern(width: 3200, height: 2000), scale: 2)
        EditorWindowController.open(item)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "PeekShot Editor" && $0.isVisible })
        let scrollView = try XCTUnwrap(firstSubview(of: NSScrollView.self, in: window.contentView))
        let canvas = try XCTUnwrap(scrollView.documentView as? CanvasView)

        XCTAssertLessThanOrEqual(scrollView.magnification, 1)
        XCTAssertTrue(scrollView.documentVisibleRect.insetBy(dx: -1, dy: -1).contains(canvas.bounds),
                      "the whole image should be visible after zoom-to-fit")
        XCTAssertTrue(window.firstResponder === canvas)
        save(viewSnapshot(of: try XCTUnwrap(window.contentView)), "editor-window")

        window.close()
        XCTAssertFalse(NSApp.windows.contains { $0.title == "PeekShot Editor" && $0.isVisible })
    }

    func testSettingsAndHistoryWindowsOpen() throws {
        SettingsWindowController.show()
        let settings = try XCTUnwrap(NSApp.windows.first { $0.title == "PeekShot Settings" && $0.isVisible })
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        save(viewSnapshot(of: try XCTUnwrap(settings.contentView)), "settings-window")
        SettingsWindowController.show(tab: .about)
        XCTAssertEqual(SettingsNavigation.shared.tab, .about)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        save(viewSnapshot(of: try XCTUnwrap(settings.contentView)), "settings-about")
        settings.close()
        SettingsNavigation.shared.tab = .general

        HistoryWindowController.show()
        let history = try XCTUnwrap(NSApp.windows.first { $0.title == "Capture History" && $0.isVisible })
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        save(viewSnapshot(of: try XCTUnwrap(history.contentView)), "history-window")
        history.close()
    }

    // MARK: Chrome

    func testEditorBarsAndQuickAccessCardRender() {
        let state = EditorState()
        let toolbar = NSHostingView(rootView: EditorToolbar(state: state))
        let toolbarWindow = host(toolbar, size: CGSize(width: 920, height: 48))
        defer { toolbarWindow.close() }
        XCTAssertLessThanOrEqual(toolbar.fittingSize.width, 920, "toolbar must fit the minimum window width")
        save(viewSnapshot(of: toolbar), "editor-toolbar")

        let footer = NSHostingView(rootView: EditorFooter(state: state, onUndo: {}, onRedo: {}, onPin: {},
                                                          onSaveAs: {}, onSave: {}, onCopy: {}))
        let footerWindow = host(footer, size: CGSize(width: 920, height: 46))
        defer { footerWindow.close() }
        save(viewSnapshot(of: footer), "editor-footer")

        let item = CaptureItem(image: testPattern(width: 1200, height: 800), scale: 2)
        let card = QuickAccessCardView(item: item, frame: CGRect(origin: .zero, size: QuickAccessController.cardSize))
        let cardWindow = host(card, size: card.frame.size)
        defer { cardWindow.close() }
        save(viewSnapshot(of: card), "card-idle")
        card.mouseEntered(with: mouse(.mouseMoved, at: CGPoint(x: 100, y: 60), in: card))
        XCTAssertTrue(card.isHovering)
        save(viewSnapshot(of: card), "card-hover")
    }
}
