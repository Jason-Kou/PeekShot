import AppKit
import Carbon.HIToolbox

enum HotKeyAction: String, CaseIterable, Identifiable {
    case captureArea, captureWindow, captureFullscreen, capturePreviousArea, captureTimer, captureScrolling, captureText
    case openHistory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureArea: return "Capture Area"
        case .captureWindow: return "Capture Window"
        case .captureFullscreen: return "Capture Fullscreen"
        case .capturePreviousArea: return "Capture Previous Area"
        case .captureTimer: return "Self-Timer"
        case .captureScrolling: return "Scrolling Capture"
        case .captureText: return "Capture Text (OCR)"
        case .openHistory: return "Capture History"
        }
    }

    /// SF Symbol shown next to the action in menus.
    var symbol: String {
        switch self {
        case .captureArea: return "rectangle.dashed"
        case .captureWindow: return "macwindow"
        case .captureFullscreen: return "display"
        case .capturePreviousArea: return "arrow.counterclockwise"
        case .captureTimer: return "timer"
        case .captureScrolling: return "scroll"
        case .captureText: return "text.viewfinder"
        case .openHistory: return "clock.arrow.circlepath"
        }
    }

    var defaultCombo: KeyCombo? {
        let mods = UInt32(controlKey | optionKey)
        switch self {
        case .captureArea: return KeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: mods, key: "A")
        case .captureWindow: return KeyCombo(keyCode: UInt32(kVK_ANSI_W), modifiers: mods, key: "W")
        case .captureFullscreen: return KeyCombo(keyCode: UInt32(kVK_ANSI_F), modifiers: mods, key: "F")
        case .capturePreviousArea: return KeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: mods, key: "R")
        case .captureTimer: return KeyCombo(keyCode: UInt32(kVK_ANSI_T), modifiers: mods, key: "T")
        case .captureScrolling: return KeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: mods, key: "S")
        case .captureText: return KeyCombo(keyCode: UInt32(kVK_ANSI_O), modifiers: mods, key: "O")
        case .openHistory: return KeyCombo(keyCode: UInt32(kVK_ANSI_H), modifiers: mods, key: "H")
        }
    }
}

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier flags (cmdKey, optionKey, controlKey, shiftKey).
    var modifiers: UInt32
    /// Human readable label of the key itself, e.g. "A" or "F5".
    var key: String

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m = 0
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.shift) { m |= shiftKey }
        if flags.contains(.command) { m |= cmdKey }
        return UInt32(m)
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Builds a combo from a key-down event; returns nil unless ⌘, ⌃ or ⌥ is held.
    static func from(event: NSEvent) -> KeyCombo? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        let label = specialKeys[Int(event.keyCode)]
            ?? event.charactersIgnoringModifiers?.uppercased()
            ?? "?"
        return KeyCombo(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers(from: flags), key: label)
    }
}

/// Global shortcuts through Carbon hot keys; this needs no accessibility permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var onAction: ((HotKeyAction) -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var actionsByID: [UInt32: HotKeyAction] = [:]
    private var handlerInstalled = false
    private var transientRefs: [EventHotKeyRef] = []
    private var transientHandlers: [UInt32: () -> Void] = [:]

    private init() {}

    /// Re-registers every shortcut from preferences.
    func reload() {
        suspend()
        installHandlerIfNeeded()
        for (index, action) in HotKeyAction.allCases.enumerated() {
            guard let combo = Prefs.keyCombo(for: action) else { continue }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x504B_5348), id: id) // 'PKSH'
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actionsByID[id] = action
            }
        }
    }

    /// Unregisters everything, e.g. while the user records a new shortcut.
    func suspend() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actionsByID.removeAll()
    }

    /// Registers a key that works while another app is active, until `removeTransientKeys()`.
    /// Used for Esc and Return while a scrolling capture runs on top of the app being captured.
    func addTransientKey(keyCode: Int, modifiers: UInt32 = 0, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = UInt32(1000 + transientHandlers.count)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x504B_5348), id: id)
        if RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
           let ref {
            transientRefs.append(ref)
            transientHandlers[id] = handler
        }
    }

    func removeTransientKeys() {
        transientRefs.forEach { UnregisterEventHotKey($0) }
        transientRefs.removeAll()
        transientHandlers.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            if let action = center.actionsByID[hotKeyID.id] {
                center.onAction?(action)
            } else if let handler = center.transientHandlers[hotKeyID.id] {
                handler()
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }
}
