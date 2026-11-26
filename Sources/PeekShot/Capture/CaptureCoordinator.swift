import AppKit

/// Runs the capture flows: area, window, full screen, previous area and self-timer.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var session: SelectionSession?
    private var busy = false
    /// The last selected area, in view coordinates of its display.
    private var lastArea: (displayID: CGDirectDisplayID, rect: CGRect)?

    func perform(_ action: HotKeyAction) {
        switch action {
        case .captureArea: startSelection(mode: .area)
        case .captureWindow: startSelection(mode: .window)
        case .captureFullscreen: captureFullscreen()
        case .capturePreviousArea: capturePreviousArea()
        case .captureTimer: startSelection(mode: .area, timerSeconds: Prefs.timerSeconds)
        case .openHistory: HistoryWindowController.show()
        }
    }

    var hasPreviousArea: Bool { lastArea != nil }

    // MARK: Flows

    private func startSelection(mode: SelectionMode, timerSeconds: Int? = nil) {
        guard !busy, ensurePermission() else { return }
        busy = true
        Task {
            do {
                // Freeze the screen first so menus and hover states survive into the capture.
                let windowInfos = WindowInfo.onScreen()
                let snapshots = try await ScreenCapturer.snapshotAllDisplays()
                let session = SelectionSession(snapshots: snapshots, windowInfos: windowInfos, mode: mode)
                self.session = session
                session.begin { [weak self] outcome in
                    self?.session = nil
                    self?.handle(outcome, timerSeconds: timerSeconds)
                }
            } catch {
                fail(error)
            }
        }
    }

    private func handle(_ outcome: SelectionOutcome, timerSeconds: Int?) {
        switch outcome {
        case .cancelled:
            busy = false
        case let .area(snapshot, rect):
            lastArea = (snapshot.displayID, rect)
            if let timerSeconds {
                let screenRect = rect.offsetBy(dx: snapshot.screen.frame.minX, dy: snapshot.screen.frame.minY)
                CountdownHUD.run(seconds: timerSeconds, around: screenRect) { [weak self] in
                    self?.captureLive(displayID: snapshot.displayID, rect: rect)
                }
            } else {
                deliver(crop(snapshot, viewRect: rect), from: snapshot)
            }
        case let .window(snapshot, window):
            Task {
                var image: CGImage?
                if let captured = try? await ScreenCapturer.captureWindow(id: window.id) {
                    image = Prefs.windowShadow ? ImageCodec.addingShadow(to: captured, scale: snapshot.scale) : captured
                } else {
                    // Fall back to cutting the window's frame out of the frozen still.
                    let viewRect = Geometry.viewRect(forGlobalRect: window.frame, displayBounds: snapshot.displayBounds)
                    image = crop(snapshot, viewRect: viewRect)
                }
                deliver(image, from: snapshot)
            }
        }
    }

    private func captureFullscreen() {
        guard !busy, ensurePermission() else { return }
        busy = true
        let screen = NSScreen.underMouse
        Task {
            do {
                let snapshot = try await ScreenCapturer.snapshot(of: screen)
                deliver(snapshot.image, from: snapshot)
            } catch {
                fail(error)
            }
        }
    }

    private func capturePreviousArea() {
        guard !busy, ensurePermission() else { return }
        guard let lastArea else {
            Toast.show("还没有截取过区域")
            return
        }
        busy = true
        captureLive(displayID: lastArea.displayID, rect: lastArea.rect)
    }

    /// Captures `rect` (view coordinates) from the display as it looks right now.
    private func captureLive(displayID: CGDirectDisplayID, rect: CGRect) {
        guard let screen = NSScreen.with(displayID: displayID) else {
            fail(CaptureError.displayNotFound)
            return
        }
        Task {
            do {
                let snapshot = try await ScreenCapturer.snapshot(of: screen)
                deliver(crop(snapshot, viewRect: rect), from: snapshot)
            } catch {
                fail(error)
            }
        }
    }

    // MARK: Helpers

    private func crop(_ snapshot: DisplaySnapshot, viewRect: CGRect) -> CGImage? {
        let size = CGSize(width: snapshot.image.width, height: snapshot.image.height)
        let pixelRect = Geometry.pixelRect(forViewRect: viewRect, viewHeight: snapshot.screen.frame.height,
                                           scale: snapshot.scale, imageSize: size)
        return ImageCodec.crop(snapshot.image, toPixelRect: pixelRect)
    }

    private func deliver(_ image: CGImage?, from snapshot: DisplaySnapshot) {
        busy = false
        guard let image else { return }
        CaptureActions.deliver(image: image, scale: snapshot.scale, on: snapshot.screen)
    }

    private func fail(_ error: Error) {
        busy = false
        if !ScreenCapturer.hasPermission {
            showPermissionAlert()
        } else {
            Toast.show("截图失败：\(error.localizedDescription)")
        }
    }

    private func ensurePermission() -> Bool {
        if ScreenCapturer.hasPermission { return true }
        // The first request makes macOS show its own prompt and list the app in System Settings.
        CGRequestScreenCaptureAccess()
        showPermissionAlert()
        return false
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "PeekShot 需要“屏幕录制”权限"
        alert.informativeText = "请在 系统设置 → 隐私与安全性 → 录屏与系统录音 中打开 PeekShot，然后重新启动 PeekShot。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A big number counting down next to the area that is about to be captured.
@MainActor
enum CountdownHUD {
    static func run(seconds: Int, around screenRect: CGRect, completion: @escaping () -> Void) {
        let size = CGSize(width: 96, height: 96)
        let panel = NSPanel(contentRect: CGRect(x: screenRect.midX - size.width / 2,
                                                y: screenRect.midY - size.height / 2,
                                                width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false

        let background = NSView(frame: CGRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        background.layer?.cornerRadius = size.width / 2
        let label = NSTextField(labelWithString: "\(seconds)")
        label.font = .monospacedDigitSystemFont(ofSize: 48, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = CGRect(x: 0, y: (size.height - 58) / 2, width: size.width, height: 58)
        background.addSubview(label)
        panel.contentView = background
        panel.orderFrontRegardless()

        var remaining = seconds
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            MainActor.assumeIsolated {
                remaining -= 1
                if remaining > 0 {
                    label.stringValue = "\(remaining)"
                    return
                }
                timer.invalidate()
                panel.orderOut(nil)
                // Give the window server a moment to take the HUD off screen before capturing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { completion() }
            }
        }
    }
}
