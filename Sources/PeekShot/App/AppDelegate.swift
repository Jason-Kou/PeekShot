import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?
    private var launchDate = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchDate = Date()
        Prefs.registerDefaults()
        NSApp.mainMenu = Self.makeMainMenu()
        statusMenu = StatusMenuController()

        ScreenCapturer.excludedWindowNumbers = {
            var numbers = QuickAccessController.shared.windowNumbers
            if let toast = Toast.windowNumber { numbers.insert(toast) }
            return numbers
        }
        HotKeyCenter.shared.onAction = { action in
            CaptureCoordinator.shared.perform(action)
        }
        HotKeyCenter.shared.reload()
        HistoryStore.shared.prune(olderThanDays: Prefs.historyDays)

        // Ask once at launch so PeekShot is listed under Screen Recording before the first capture.
        // macOS shows its prompt only the first time; unit test runs must not trigger it.
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !ScreenCapturer.hasPermission, !isRunningTests {
            CGRequestScreenCaptureAccess()
        }
        NSLog("PeekShot: screen recording permission %@", ScreenCapturer.hasPermission ? "granted" : "missing")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quits and starts the app again, e.g. to pick up a freshly granted screen recording permission.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Opening the app again while it runs shows the settings window, so everything stays reachable
    /// when the menu bar icon is hidden behind the notch or crowded out by other icons.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The launch itself also arrives here; only a later, deliberate reopen should show the window.
        if Date().timeIntervalSince(launchDate) > 2 {
            SettingsWindowController.show()
        }
        return false
    }

    /// URL scheme for scripts and launchers: `open peekshot://capture-area`.
    /// Hosts: capture-area, capture-window, capture-fullscreen, capture-previous-area, capture-timer,
    /// capture-scrolling, capture-text, history, settings, about.
    func application(_ application: NSApplication, open urls: [URL]) {
        let actions: [String: HotKeyAction] = [
            "capture-area": .captureArea, "capture-window": .captureWindow,
            "capture-fullscreen": .captureFullscreen, "capture-previous-area": .capturePreviousArea,
            "capture-timer": .captureTimer, "capture-scrolling": .captureScrolling, "capture-text": .captureText,
            "history": .openHistory,
        ]
        for url in urls {
            if url.host == "settings" {
                SettingsWindowController.show()
            } else if url.host == "about" {
                SettingsWindowController.show(tab: .about)
            } else if let host = url.host, let action = actions[host] {
                CaptureCoordinator.shared.perform(action)
            }
        }
    }

    /// A menu-bar app shows no main menu, but text fields still need it for ⌘C / ⌘V / ⌘Z.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }
}

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    override init() {
        super.init()
        statusItem.button?.image = Self.statusIcon()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The app icon's two corner brackets as a template image, so the menu bar matches the app.
    static func statusIcon() -> NSImage {
        let image = NSImage(size: CGSize(width: 18, height: 18), flipped: false) { rect in
            let frame = rect.insetBy(dx: 3.5, dy: 3.5)
            let arm: CGFloat = 6, radius: CGFloat = 2
            let path = NSBezierPath()
            // Top-left bracket.
            path.move(to: CGPoint(x: frame.minX + arm, y: frame.maxY))
            path.appendArc(from: CGPoint(x: frame.minX, y: frame.maxY),
                           to: CGPoint(x: frame.minX, y: frame.maxY - arm), radius: radius)
            path.line(to: CGPoint(x: frame.minX, y: frame.maxY - arm))
            // Bottom-right bracket.
            path.move(to: CGPoint(x: frame.maxX - arm, y: frame.minY))
            path.appendArc(from: CGPoint(x: frame.maxX, y: frame.minY),
                           to: CGPoint(x: frame.maxX, y: frame.minY + arm), radius: radius)
            path.line(to: CGPoint(x: frame.maxX, y: frame.minY + arm))
            path.lineWidth = 2.2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "PeekShot"
        return image
    }

    /// Rebuilt on every open so shortcut hints follow the settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // The menu disables items itself only when asked; "Capture Previous Area" depends on state.
        menu.autoenablesItems = false
        let groups: [[HotKeyAction]] = [
            [.captureArea, .captureWindow, .captureFullscreen, .capturePreviousArea],
            [.captureTimer, .captureScrolling, .captureText],
        ]
        for group in groups {
            for action in group {
                let title = action == .captureTimer ? "Self-Timer (\(Prefs.timerSeconds)s)" : action.title
                let item = add(title, #selector(runHotKeyAction(_:)), symbol: action.symbol,
                               shortcut: Prefs.keyCombo(for: action))
                item.representedObject = action.rawValue
                if action == .capturePreviousArea { item.isEnabled = CaptureCoordinator.shared.hasPreviousArea }
            }
            menu.addItem(.separator())
        }
        add("Pin Image from Clipboard", #selector(pinClipboard), symbol: "pin")
        add("Open Image to Annotate…", #selector(openImage), symbol: "pencil.and.outline")
        add(HotKeyAction.openHistory.title, #selector(runHotKeyAction(_:)), symbol: HotKeyAction.openHistory.symbol,
            shortcut: Prefs.keyCombo(for: .openHistory)).representedObject = HotKeyAction.openHistory.rawValue
        menu.addItem(.separator())
        add("Settings…", #selector(openSettings), symbol: "gearshape")
        add("About PeekShot", #selector(openAbout), symbol: "info.circle")
        menu.addItem(.separator())
        add("Quit PeekShot", #selector(quit), symbol: "power")
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, symbol: String, shortcut: KeyCombo? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if let shortcut, shortcut.key.count == 1 {
            item.keyEquivalent = shortcut.key.lowercased()
            item.keyEquivalentModifierMask = shortcut.cocoaModifiers
        }
        menu.addItem(item)
        return item
    }

    @objc private func runHotKeyAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = HotKeyAction(rawValue: raw) else { return }
        // Let the menu close first so it does not end up in the screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CaptureCoordinator.shared.perform(action)
        }
    }

    @objc private func pinClipboard() {
        guard let image = ImageCodec.imageFromPasteboard() else {
            Toast.show("No image on the clipboard")
            return
        }
        CaptureActions.pin(CaptureItem(image: image, scale: 1))
    }

    @objc private func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let loaded = ImageCodec.load(url) else { return }
        // Edit a copy in history so the original file is never overwritten.
        CaptureActions.edit(HistoryStore.shared.add(image: loaded.image, scale: loaded.scale))
    }

    @objc private func openSettings() { SettingsWindowController.show() }
    @objc private func openAbout() { SettingsWindowController.show(tab: .about) }
    @objc private func quit() { NSApp.terminate(nil) }
}
