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
    /// Hosts: capture-area, capture-window, capture-fullscreen, capture-previous-area, capture-timer, history, settings.
    func application(_ application: NSApplication, open urls: [URL]) {
        let actions: [String: HotKeyAction] = [
            "capture-area": .captureArea, "capture-window": .captureWindow,
            "capture-fullscreen": .captureFullscreen, "capture-previous-area": .capturePreviousArea,
            "capture-timer": .captureTimer, "history": .openHistory,
        ]
        for url in urls {
            if url.host == "settings" {
                SettingsWindowController.show()
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
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "PeekShot")
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt on every open so shortcut hints follow the settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let captures: [HotKeyAction] = [.captureArea, .captureWindow, .captureFullscreen, .capturePreviousArea, .captureTimer]
        for action in captures {
            let title = action == .captureTimer ? "Self-Timer (\(Prefs.timerSeconds)s)" : action.title
            let item = add(title, #selector(runHotKeyAction(_:)), shortcut: Prefs.keyCombo(for: action))
            item.representedObject = action.rawValue
            if action == .capturePreviousArea { item.isEnabled = CaptureCoordinator.shared.hasPreviousArea }
        }
        menu.addItem(.separator())
        add("Pin Image from Clipboard", #selector(pinClipboard))
        add("Open Image to Annotate…", #selector(openImage))
        add("Capture History", #selector(runHotKeyAction(_:)), shortcut: Prefs.keyCombo(for: .openHistory))
            .representedObject = HotKeyAction.openHistory.rawValue
        menu.addItem(.separator())
        add("Settings…", #selector(openSettings))
        add("Quit PeekShot", #selector(quit))
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, shortcut: KeyCombo? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
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
    @objc private func quit() { NSApp.terminate(nil) }
}
