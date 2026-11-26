import AppKit
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static var underMouse: NSScreen {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) } ?? main ?? screens[0]
    }

    static func with(displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }
}

/// A full-resolution still of one display.
struct DisplaySnapshot {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let image: CGImage

    /// Pixels per point of the captured image.
    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
    /// Display bounds in global (top-left origin) coordinates.
    var displayBounds: CGRect { CGDisplayBounds(displayID) }
}

/// An on-screen window as reported by the window server, front to back.
struct WindowInfo {
    let id: CGWindowID
    /// Frame in global (top-left origin) coordinates.
    let frame: CGRect

    static func onScreen() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        return list.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? Int) != ownPID,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = entry[kCGWindowNumber as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict),
                  frame.width >= 40, frame.height >= 40
            else { return nil }
            return WindowInfo(id: CGWindowID(id), frame: frame)
        }
    }
}

enum CaptureError: LocalizedError {
    case displayNotFound
    case windowNotFound

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "找不到要截取的显示器。"
        case .windowNotFound: return "找不到要截取的窗口。"
        }
    }
}

@MainActor
enum ScreenCapturer {
    /// Window numbers of our own transient UI (quick access cards, toasts) to keep out of captures.
    static var excludedWindowNumbers: () -> Set<Int> = { [] }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func snapshotAllDisplays() async throws -> [DisplaySnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var snapshots: [DisplaySnapshot] = []
        for screen in NSScreen.screens {
            if let snapshot = try await snapshot(of: screen, content: content) {
                snapshots.append(snapshot)
            }
        }
        guard !snapshots.isEmpty else { throw CaptureError.displayNotFound }
        return snapshots
    }

    static func snapshot(of screen: NSScreen) async throws -> DisplaySnapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let snapshot = try await snapshot(of: screen, content: content) else { throw CaptureError.displayNotFound }
        return snapshot
    }

    private static func snapshot(of screen: NSScreen, content: SCShareableContent) async throws -> DisplaySnapshot? {
        let displayID = screen.displayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
        let excludedIDs = excludedWindowNumbers()
        let excluded = content.windows.filter { excludedIDs.contains(Int($0.windowID)) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                               configuration: configuration(for: filter))
        return DisplaySnapshot(screen: screen, displayID: displayID, image: image)
    }

    /// Captures one window on its own, without shadow and with transparent corners.
    static func captureWindow(id: CGWindowID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.windowNotFound }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = configuration(for: filter)
        config.ignoreShadowsSingleWindow = true
        config.backgroundColor = .clear
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func configuration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        return config
    }
}
