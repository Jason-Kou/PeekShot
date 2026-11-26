import AppKit
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpg
    var id: String { rawValue }
    var utType: UTType { self == .png ? .png : .jpeg }
    var title: String { self == .png ? "PNG" : "JPG" }
}

enum OverlayPosition: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var title: String { self == .left ? "左下角" : "右下角" }
}

/// UserDefaults keys. SwiftUI settings bind to the same keys through @AppStorage.
enum PrefKey {
    static let playSound = "playSound"
    static let showQuickAccess = "showQuickAccess"
    static let copyAfterCapture = "copyAfterCapture"
    static let saveAfterCapture = "saveAfterCapture"
    static let saveDirectory = "saveDirectory"
    static let imageFormat = "imageFormat"
    static let overlayPosition = "overlayPosition"
    static let overlayAutoClose = "overlayAutoCloseSeconds"
    static let historyDays = "historyRetentionDays"
    static let windowShadow = "windowShadow"
    static let showMagnifier = "showMagnifier"
    static let timerSeconds = "timerSeconds"
    static func hotKey(_ action: HotKeyAction) -> String { "hotkey.\(action.rawValue)" }
}

enum Prefs {
    static let defaults = UserDefaults.standard

    static func registerDefaults() {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        defaults.register(defaults: [
            PrefKey.playSound: true,
            PrefKey.showQuickAccess: true,
            PrefKey.copyAfterCapture: false,
            PrefKey.saveAfterCapture: false,
            PrefKey.saveDirectory: desktop.path,
            PrefKey.imageFormat: ImageFormat.png.rawValue,
            PrefKey.overlayPosition: OverlayPosition.left.rawValue,
            PrefKey.overlayAutoClose: 0,
            PrefKey.historyDays: 30,
            PrefKey.windowShadow: true,
            PrefKey.showMagnifier: true,
            PrefKey.timerSeconds: 5,
        ])
    }

    static var playSound: Bool { defaults.bool(forKey: PrefKey.playSound) }
    static var showQuickAccess: Bool { defaults.bool(forKey: PrefKey.showQuickAccess) }
    static var copyAfterCapture: Bool { defaults.bool(forKey: PrefKey.copyAfterCapture) }
    static var saveAfterCapture: Bool { defaults.bool(forKey: PrefKey.saveAfterCapture) }
    static var windowShadow: Bool { defaults.bool(forKey: PrefKey.windowShadow) }
    static var showMagnifier: Bool { defaults.bool(forKey: PrefKey.showMagnifier) }
    static var overlayAutoClose: Int { defaults.integer(forKey: PrefKey.overlayAutoClose) }
    static var historyDays: Int { defaults.integer(forKey: PrefKey.historyDays) }
    static var timerSeconds: Int { max(1, defaults.integer(forKey: PrefKey.timerSeconds)) }

    static var saveDirectory: URL {
        URL(fileURLWithPath: defaults.string(forKey: PrefKey.saveDirectory) ?? NSHomeDirectory(), isDirectory: true)
    }
    static var imageFormat: ImageFormat {
        ImageFormat(rawValue: defaults.string(forKey: PrefKey.imageFormat) ?? "") ?? .png
    }
    static var overlayPosition: OverlayPosition {
        OverlayPosition(rawValue: defaults.string(forKey: PrefKey.overlayPosition) ?? "") ?? .left
    }

    /// Returns the stored shortcut, the built-in default when never set, or nil when cleared by the user.
    static func keyCombo(for action: HotKeyAction) -> KeyCombo? {
        guard let data = defaults.data(forKey: PrefKey.hotKey(action)) else { return action.defaultCombo }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    static func setKeyCombo(_ combo: KeyCombo?, for action: HotKeyAction) {
        let data = combo.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(data, forKey: PrefKey.hotKey(action))
    }
}
