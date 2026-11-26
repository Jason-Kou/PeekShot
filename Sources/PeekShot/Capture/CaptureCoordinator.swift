import AppKit

/// Runs the capture flows: area, window, full screen, previous area, self-timer and text recognition.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var session: SelectionSession?
    private var busy = false
    /// The last selected area, in view coordinates of its display.
    private var lastArea: (displayID: CGDirectDisplayID, rect: CGRect)?

    /// What happens with the selected region.
    private enum Purpose {
        case image
        case timer(seconds: Int)
        case text
    }

    func perform(_ action: HotKeyAction) {
        switch action {
        case .captureArea: startSelection(mode: .area, purpose: .image)
        case .captureWindow: startSelection(mode: .window, purpose: .image)
        case .captureFullscreen: captureFullscreen()
        case .capturePreviousArea: capturePreviousArea()
        case .captureTimer: startSelection(mode: .area, purpose: .timer(seconds: Prefs.timerSeconds))
        case .captureText: startSelection(mode: .area, purpose: .text)
        case .openHistory: HistoryWindowController.show()
        }
    }

    var hasPreviousArea: Bool { lastArea != nil }

    // MARK: Flows

    private func startSelection(mode: SelectionMode, purpose: Purpose) {
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
                    self?.handle(outcome, purpose: purpose)
                }
            } catch {
                fail(error)
            }
        }
    }

    private func handle(_ outcome: SelectionOutcome, purpose: Purpose) {
        switch (outcome, purpose) {
        case (.cancelled, _):
            busy = false
        case let (.area(snapshot, rect), .text):
            recognizeText(in: crop(snapshot, viewRect: rect))
        case let (.window(snapshot, window), .text):
            let viewRect = Geometry.viewRect(forGlobalRect: window.frame, displayBounds: snapshot.displayBounds)
            recognizeText(in: crop(snapshot, viewRect: viewRect))
        case let (.area(snapshot, rect), .timer(seconds)):
            lastArea = (snapshot.displayID, rect)
            let screenRect = rect.offsetBy(dx: snapshot.screen.frame.minX, dy: snapshot.screen.frame.minY)
            CountdownHUD.run(seconds: seconds, around: screenRect) { [weak self] in
                self?.captureLive(displayID: snapshot.displayID, rect: rect)
            }
        case let (.area(snapshot, rect), .image):
            lastArea = (snapshot.displayID, rect)
            deliver(crop(snapshot, viewRect: rect), from: snapshot)
        case let (.window(snapshot, window), _):
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

    /// Copies the text found in the image to the clipboard.
    private func recognizeText(in image: CGImage?) {
        busy = false
        guard let image else { return }
        Task {
            let text = await TextRecognizer.recognize(in: image)
            if text.isEmpty {
                Toast.show("No text found")
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                Toast.show("Text copied to clipboard")
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
            Toast.show("No previous area yet")
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
            Toast.show("Capture failed: \(error.localizedDescription)")
        }
    }

    private func ensurePermission() -> Bool {
        // The system prompt itself is requested once at launch (see AppDelegate).
        if ScreenCapturer.hasPermission { return true }
        showPermissionAlert()
        return false
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "PeekShot needs Screen Recording permission"
        alert.informativeText = "Turn on PeekShot in System Settings → Privacy & Security → Screen & System Audio Recording.\n"
            + "macOS reads this permission only when the app starts: if the switch is already on, click Relaunch PeekShot."
        alert.addButton(withTitle: "Relaunch PeekShot")
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            AppDelegate.relaunch()
        case .alertSecondButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
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
