import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A menu-bar app shows no main menu, but text fields still need it for ⌘C / ⌘V / ⌘Z.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
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
            let title = action == .captureTimer ? "延时截图（\(Prefs.timerSeconds) 秒）" : action.title
            let item = add(title, #selector(runHotKeyAction(_:)), shortcut: Prefs.keyCombo(for: action))
            item.representedObject = action.rawValue
            if action == .capturePreviousArea { item.isEnabled = CaptureCoordinator.shared.hasPreviousArea }
        }
        menu.addItem(.separator())
        add("贴图剪贴板中的图片", #selector(pinClipboard))
        add("打开图片进行标注…", #selector(openImage))
        add("截图历史", #selector(runHotKeyAction(_:)), shortcut: Prefs.keyCombo(for: .openHistory))
            .representedObject = HotKeyAction.openHistory.rawValue
        menu.addItem(.separator())
        add("设置…", #selector(openSettings))
        add("退出 PeekShot", #selector(quit))
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
            Toast.show("剪贴板里没有图片")
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
